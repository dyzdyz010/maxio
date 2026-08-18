use rustler::{Binary, Env, NewBinary};
use std::collections::BTreeMap;

/// 把长度向上取到偶数（reed-solomon-simd 要求分片长为偶数；GF(2^16) 16-bit 符号）。
fn even_up(n: usize) -> usize {
    if n % 2 == 0 {
        n
    } else {
        n + 1
    }
}

/// 由字节切片构造 Elixir binary（Vec<u8> 会被编码成整数列表而非 binary，必须显式用 NewBinary）。
fn to_bin<'a>(env: Env<'a>, data: &[u8]) -> Binary<'a> {
    let mut b = NewBinary::new(env, data.len());
    b.as_mut_slice().copy_from_slice(data);
    b.into()
}

/// 把 `data` 编码为 K 个数据分片 + M 个校验分片（N = K + M），返回 N 个等长 binary 列表
/// （前 K 个为数据分片、systematic；后 M 个为校验分片）。
/// shard_len = even(ceil(len/K))，末数据分片零填充；调用方须保存原始 byte_size(data) 以便重建后截断。
#[rustler::nif]
fn native_rs_encode<'a>(
    env: Env<'a>,
    data_shards: usize,
    parity_shards: usize,
    data: Binary<'a>,
) -> Result<Vec<Binary<'a>>, String> {
    if data_shards == 0 || parity_shards == 0 {
        return Err(format!(
            "data_shards and parity_shards must be > 0 (got {data_shards},{parity_shards})"
        ));
    }
    let bytes = data.as_slice();
    let shard_len = even_up((bytes.len() + data_shards - 1) / data_shards).max(2);

    // 切分 + 零填充为 K 个等长偶数长度数据分片。
    let mut data_owned: Vec<Vec<u8>> = Vec::with_capacity(data_shards);
    for i in 0..data_shards {
        let start = i * shard_len;
        let mut shard = vec![0u8; shard_len];
        if start < bytes.len() {
            let end = (start + shard_len).min(bytes.len());
            shard[..end - start].copy_from_slice(&bytes[start..end]);
        }
        data_owned.push(shard);
    }

    // 编码 -> M 个校验分片。
    let parity: Vec<Vec<u8>> =
        reed_solomon_simd::encode(data_shards, parity_shards, data_owned.iter())
            .map_err(|e| format!("rs encode failed: {e}"))?;

    // 发出全部 N 个分片（数据在前、校验在后）为 Elixir binary。
    let mut out: Vec<Binary<'a>> = Vec::with_capacity(data_shards + parity_shards);
    for s in &data_owned {
        out.push(to_bin(env, s));
    }
    for s in &parity {
        out.push(to_bin(env, s));
    }
    Ok(out)
}

/// 从长度为 N = data_shards + parity_shards 的分片列表重建原始数据
/// （缺失/损坏分片为 `nil` -> None）。至少需 data_shards 个分片在场。
/// 返回 {:ok, 重建数据 binary}，长度 = data_shards * shard_len（调用方按存储的原始长度截断）。
#[rustler::nif]
fn native_rs_reconstruct<'a>(
    env: Env<'a>,
    data_shards: usize,
    parity_shards: usize,
    shards: Vec<Option<Binary<'a>>>,
) -> Result<Binary<'a>, String> {
    let total = data_shards + parity_shards;
    if shards.len() != total {
        return Err(format!(
            "expected {total} shards (={data_shards}+{parity_shards}), got {}",
            shards.len()
        ));
    }
    let present = shards.iter().filter(|s| s.is_some()).count();
    if present < data_shards {
        return Err(format!(
            "need at least {data_shards} shards to reconstruct, only {present} present"
        ));
    }

    // 由任一存活分片确定 shard_len。
    let shard_len = shards
        .iter()
        .filter_map(|s| s.as_ref())
        .map(|b| b.as_slice().len())
        .next()
        .ok_or_else(|| "no shards present".to_string())?;

    // 快路径：K 个数据分片全在 -> 直接拼接（systematic 码，无需解码）。
    let all_data_present = (0..data_shards).all(|i| shards[i].is_some());
    if all_data_present {
        let mut out = NewBinary::new(env, data_shards * shard_len);
        let buf = out.as_mut_slice();
        for i in 0..data_shards {
            let s = shards[i].as_ref().unwrap().as_slice();
            buf[i * shard_len..(i + 1) * shard_len].copy_from_slice(s);
        }
        return Ok(out.into());
    }

    // 解码路径：拆存活分片为 (index, bytes) 的 originals 与 recovery。
    let originals: Vec<(usize, &[u8])> = (0..data_shards)
        .filter_map(|i| shards[i].as_ref().map(|b| (i, b.as_slice())))
        .collect();
    let recovery: Vec<(usize, &[u8])> = (0..parity_shards)
        .filter_map(|j| shards[data_shards + j].as_ref().map(|b| (j, b.as_slice())))
        .collect();

    let restored: BTreeMap<usize, Vec<u8>> = reed_solomon_simd::decode(
        data_shards,
        parity_shards,
        originals.iter().copied(),
        recovery.iter().copied(),
    )
    .map_err(|e| format!("rs decode failed: {e}"))?;

    // 重组 K 个数据分片：存活 originals + 恢复出的。
    let mut out = NewBinary::new(env, data_shards * shard_len);
    let buf = out.as_mut_slice();
    for i in 0..data_shards {
        let slot = &mut buf[i * shard_len..(i + 1) * shard_len];
        if let Some(b) = shards[i].as_ref() {
            slot.copy_from_slice(b.as_slice());
        } else if let Some(r) = restored.get(&i) {
            slot.copy_from_slice(r);
        } else {
            return Err(format!("shard {i} neither present nor restored"));
        }
    }
    Ok(out.into())
}

/// BLAKE3-256 摘要（32 字节 binary）。用于 per-shard bitrot 校验和。
#[rustler::nif]
fn native_blake3<'a>(env: Env<'a>, data: Binary<'a>) -> Binary<'a> {
    let hash = blake3::hash(data.as_slice());
    to_bin(env, hash.as_bytes())
}

/// Stat one path component without following its final link.
///
/// Windows uses the reparse-point attribute so this covers symbolic links, junctions and other
/// name-surrogate objects. Unix reports symbolic links. Errors are reduced to a fixed code
/// whitelist so neither OS text nor the supplied path can escape into proof evidence.
#[rustler::nif(schedule = "DirtyIo")]
fn native_path_reparse_point(path: String) -> Result<bool, String> {
    let metadata = std::fs::symlink_metadata(path).map_err(path_error_code)?;

    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        Ok(metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0)
    }

    #[cfg(not(windows))]
    {
        Ok(metadata.file_type().is_symlink())
    }
}

fn path_error_code(error: std::io::Error) -> String {
    use std::io::ErrorKind;

    let code = match error.kind() {
        ErrorKind::NotFound => "enoent",
        ErrorKind::PermissionDenied => "eacces",
        ErrorKind::InvalidInput => "einval",
        ErrorKind::TimedOut => "etimedout",
        _ => raw_path_error_code(error.raw_os_error()),
    };

    code.to_string()
}

#[cfg(windows)]
fn raw_path_error_code(raw: Option<i32>) -> &'static str {
    match raw {
        Some(2 | 3) => "enoent",
        Some(5) => "eacces",
        Some(123) => "einval",
        Some(170) => "ebusy",
        Some(267) => "enotdir",
        Some(1460) => "etimedout",
        _ => "eio",
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn raw_path_error_code(raw: Option<i32>) -> &'static str {
    match raw {
        Some(2) => "enoent",
        Some(13) => "eacces",
        Some(16) => "ebusy",
        Some(20) => "enotdir",
        Some(22) => "einval",
        Some(40) => "eloop",
        Some(110) => "etimedout",
        Some(116) => "estale",
        _ => "eio",
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn raw_path_error_code(raw: Option<i32>) -> &'static str {
    match raw {
        Some(2) => "enoent",
        Some(13) => "eacces",
        Some(16) => "ebusy",
        Some(20) => "enotdir",
        Some(22) => "einval",
        Some(62) => "eloop",
        Some(60) => "etimedout",
        Some(70) => "estale",
        _ => "eio",
    }
}

#[cfg(all(
    unix,
    not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios"
    ))
))]
fn raw_path_error_code(raw: Option<i32>) -> &'static str {
    match raw {
        Some(2) => "enoent",
        Some(13) => "eacces",
        Some(16) => "ebusy",
        Some(20) => "enotdir",
        Some(22) => "einval",
        _ => "eio",
    }
}

#[cfg(not(any(unix, windows)))]
fn raw_path_error_code(_raw: Option<i32>) -> &'static str {
    "eio"
}

// 单参自动发现形式（与 huanxi 的 rustler::init!("Elixir.Huanxi.Geo.H3"); 一致）。
rustler::init!("Elixir.Maxio.Native");
