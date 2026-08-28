defmodule Maxio.Admin.GroupProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_group_s4", __DIR__)

  setup_all do
    fixtures =
      for name <- [
            "minio_routes_and_errors",
            "madmin_group_wire",
            "mc_group_human",
            "mc_group_json"
          ],
          into: %{} do
        path = Path.join(@fixture_dir, name <> ".json")
        {name, path |> File.read!() |> Jason.decode!()}
      end

    {:ok, fixtures}
  end

  test "pins immutable upstream identities and source URLs", fixtures do
    routes = fixtures["minio_routes_and_errors"]
    wire = fixtures["madmin_group_wire"]
    human = fixtures["mc_group_human"]
    json = fixtures["mc_group_json"]

    assert routes["fixture_id"] == "minio-admin-group-s4-routes-errors-v1"
    assert wire["fixture_id"] == "madmin-go-v3.0.109-group-wire-v1"
    assert human["fixture_id"] == "mc-77f82e1-admin-group-human-v1"
    assert json["fixture_id"] == "mc-77f82e1-admin-group-json-v1"

    assert routes["pins"] == %{
             "mc" => "77f82e18b5401a65958f1619df6ebb994634bd88",
             "mc_selected_madmin_go" => "4b504b82db633e978a57d49443b2be75824244c3",
             "madmin_go" => "6897865311e2be91d814ea0ef4814a730d87d1cd",
             "minio" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f",
             "minio_go_tag" => "v7.0.91",
             "minio_pkg" => "63a2eac5884b50aede4df00b84d16060dfd6791d"
           }

    urls =
      Enum.flat_map([routes, wire, human, json], fn fixture ->
        Enum.map(fixture["provenance"], & &1["url"])
      end)

    assert urls != []

    assert Enum.all?(urls, fn url ->
             String.starts_with?(url, "https://github.com/") and
               not String.contains?(url, "/blob/master/") and
               not String.contains?(url, "/blob/main/")
           end)
  end

  test "freezes exact G1-G4 route, action, and success transport matrix", fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert Enum.map(routes["routes"], fn route ->
             {route["id"], route["method"], route["path"], route["required_query"],
              route["actions_any_of"]}
           end) == [
             {"G1", "GET", "/minio/admin/v3/groups", %{}, ["admin:ListGroups"]},
             {"G2", "GET", "/minio/admin/v3/group", %{"group" => "NAME"}, ["admin:GetGroup"]},
             {"G3", "PUT", "/minio/admin/v3/update-group-members", %{}, ["admin:AddUserToGroup"]},
             {"G4", "PUT", "/minio/admin/v3/set-group-status",
              %{"group" => "NAME", "status" => "enabled|disabled"}, ["admin:EnableGroup"]}
           ]

    [g1, g2, g3, g4] = routes["routes"]

    for route <- [g1, g2] do
      assert route["success"]["status"] == 200
      assert route["success"]["content_type"] == "application/json"
      assert route["success"]["content_length"] == "exact_encoded_byte_length"
    end

    for route <- [g3, g4] do
      assert route["success"] == %{
               "body_bytes" => "",
               "content_type" => "absent",
               "response_writer" => "none_implicit_net_http_success",
               "status" => 200
             }
    end

    assert g3["defined_but_not_used_action"] == "admin:RemoveUserFromGroup"
    assert g4["defined_but_not_used_action"] == "admin:DisableGroup"
    assert routes["authorization_semantics"]["validate_admin_req_multiple_actions"] == "OR"

    assert routes["authorization_semantics"]["actions_within_each_group_handler"] ==
             "exactly_one"
  end

  test "freezes plaintext GroupAddRemove shape, byte lengths, and ignored groupStatus",
       fixtures do
    wire = fixtures["madmin_group_wire"]
    shape = wire["json_structs"]["GroupAddRemove"]

    assert shape["fields_in_source_order"] == [
             "group",
             "members",
             "groupStatus",
             "isRemove"
           ]

    assert shape["omitempty_fields"] == []
    assert wire["request_builder"]["application_envelope"] == "none"
    refute wire["request_builder"]["EncryptData"]
    refute wire["request_builder"]["DecryptData"]
    refute wire["request_builder"]["automatic_content_type"]

    requests = index_by_id(wire["exact_requests"])

    for id <- [
          "add_fresh_raw_order_duplicates",
          "remove_members",
          "delete_empty_group",
          "nonempty_group_status_is_accepted_and_ignored"
        ] do
      request = requests[id]
      assert request["content_type"] == "absent"
      assert byte_size(request["body"]) == request["body_utf8_length"]
      assert request["content_length"] == request["body_utf8_length"]
      assert Jason.decode!(request["body"])["groupStatus"] |> is_binary()
    end

    add = requests["add_fresh_raw_order_duplicates"]
    assert Jason.decode!(add["body"])["members"] == ["bob", "alice", "bob"]
    assert Jason.decode!(add["body"])["groupStatus"] == ""

    ignored = requests["nonempty_group_status_is_accepted_and_ignored"]
    assert Jason.decode!(ignored["body"])["groupStatus"] == "ignored-by-local-handler"
    refute ignored["local_status_mutation"]

    assert requests["enable_group"]["framing"] ==
             "VERIFY-AT-IMPL:set_status_actual_framing"

    assert requests["disable_group"]["framing"] ==
             "VERIFY-AT-IMPL:set_status_actual_framing"
  end

  test "freezes exact GroupDesc/list response bytes and sort split", fixtures do
    wire = fixtures["madmin_group_wire"]
    responses = index_by_id(wire["exact_success_responses"])

    for id <- ["get_group", "list_groups"] do
      response = responses[id]
      assert response["status"] == 200
      assert response["content_type"] == "application/json"
      assert byte_size(response["body"]) == response["content_length"]
      assert {:ok, _decoded} = Jason.decode(response["body"])
    end

    assert Jason.decode!(responses["get_group"]["body"])["members"] == ["alice", "bob"]
    assert Jason.decode!(responses["list_groups"]["body"]) == ["a-group", "z-group"]

    assert wire["sorting"]["fresh_create_members"] == "raw_request_order_with_duplicates"

    assert wire["sorting"]["existing_group_set_mutation_members"] ==
             "lexicographically_sorted_unique"

    for id <- ["update_group_members", "set_group_status"] do
      assert responses[id]["accepted_statuses"] == [200]
      assert responses[id]["body"] == ""
      assert responses[id]["content_type"] == "absent"
    end
  end

  test "freezes lifecycle, cleanup, error precedence, and exact public errors", fixtures do
    routes = fixtures["minio_routes_and_errors"]
    lifecycle = routes["lifecycle"]
    precedence = routes["validation_precedence"]

    assert lifecycle["add_missing_group"] ==
             "create_enabled_group_with_raw_request_member_slice"

    assert lifecycle["remove_down_to_zero_members"] == "preserve_empty_group"
    assert lifecycle["delete_group"] == "isRemove_true_with_empty_members_only"
    assert lifecycle["delete_empty_cleanup"] == ["group", "mapped_policy"]
    assert lifecycle["delete_empty_sequential_retry"] == "XMinioAdminNoSuchGroup"

    cross = Map.new(precedence["cross_matrix"], &{&1["case"], &1["result"]})
    assert cross["missing-user + missing-group"] == "XMinioAdminNoSuchUser"

    assert cross["empty-group + missing ordinary user"] ==
             "XMinioAdminInvalidArgument"

    assert cross["temp-or-root member + empty-group"] == "XMinioIAMActionNotAllowed"
    assert cross["invalid status + missing-group"] == "XMinioAdminInvalidArgument"

    errors = Map.new(routes["public_errors"], &{&1["code"], &1})

    assert errors["XMinioAdminNoSuchUser"] == %{
             "code" => "XMinioAdminNoSuchUser",
             "message" => "The specified user does not exist.",
             "status" => 404
           }

    assert errors["XMinioAdminNoSuchGroup"]["status"] == 404
    assert errors["XMinioAdminGroupNotEmpty"]["status"] == 400

    assert errors["XMinioAdminGroupNotEmpty"]["message"] ==
             "The specified group is not empty - cannot remove it."

    assert routes["error_response_shape"]["fields_in_source_order"] == [
             "Code",
             "Message",
             "Key",
             "BucketName",
             "Resource",
             "Region",
             "RequestId",
             "HostId",
             "ActualObjectSize",
             "RangeRequested"
           ]

    assert routes["error_response_shape"]["required_fields"] == [
             "Code",
             "Message",
             "Resource",
             "RequestId",
             "HostId"
           ]

    assert routes["error_response_shape"]["omitempty_fields"] == [
             "Key",
             "BucketName",
             "Region",
             "ActualObjectSize",
             "RangeRequested"
           ]
  end

  test "keeps exactly four VERIFY boundaries and exactly two deliberate deviations", fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert Enum.map(routes["verify_at_impl"], & &1["id"]) == [
             "set_status_actual_framing",
             "cross_node_group_race",
             "absent_remove_updated_at_cross_node_reload",
             "dynamic_mc_fatal_output"
           ]

    assert Enum.all?(routes["verify_at_impl"], fn boundary ->
             boundary["rule"] == "no observed claim until live evidence exists"
           end)

    assert Enum.map(routes["deliberate_deviations"], & &1["id"]) == [
             "maxio-sorted-unique-members",
             "maxio-persist-fresh-absent-remove-updated-at"
           ]

    assert routes["upstream_timestamp_split"] == %{
             "operation" => "remove_existing_user_absent_from_group",
             "persisted_value" => "old UpdatedAt because saveGroupInfo precedes assignment",
             "returned_and_cache_value" => "fresh UpdatedAt assigned after save"
           }

    assert routes["maxio_safety_contract"]["scope"] ==
             "local safety contract, not upstream parity"
  end

  test "freezes exact mc argv and human stdout including empty-list LF", fixtures do
    human = fixtures["mc_group_human"]

    assert human["argv"]["add"] == [
             "mc",
             "admin",
             "group",
             "add",
             "ALIAS",
             "g1",
             "alice",
             "bob"
           ]

    assert human["argv"]["remove_members_short_alias"] |> Enum.at(3) == "rm"
    assert human["argv"]["list_short_alias"] |> Enum.at(3) == "ls"

    assert human["success_stdout"] == %{
             "add" => "Added members `alice,bob` to group `g1` successfully.\n",
             "disable" => "Disabled group `g1` successfully.\n",
             "empty_list" => "\n",
             "enable" => "Enabled group `g1` successfully.\n",
             "info" => "Group: g1\nStatus: enabled\nPolicy: p-read,p-write\nMembers: alice,bob\n",
             "list" => "a-group\nz-group\n",
             "remove_group" => "Removed group g1 successfully.\n",
             "remove_members" => "Removed members {alice,bob} from group g1 successfully.\n"
           }

    assert Enum.all?(human["success_stdout"], fn {_id, stdout} -> one_trailing_lf?(stdout) end)
    assert human["dynamic_error_boundary"]["complete_stderr_and_exit"] == "VERIFY-AT-IMPL"
    refute human["dynamic_error_boundary"]["source_prefix_is_complete_stderr"]
  end

  test "freezes mc compact/TTY JSON field order, omission, and trailing LF", fixtures do
    json = fixtures["mc_group_json"]

    assert json["message_schema"]["fields_in_source_order"] == [
             "status",
             "groupName",
             "groups",
             "members",
             "groupStatus",
             "groupPolicy"
           ]

    assert json["message_schema"]["omitempty_fields"] == [
             "groupName",
             "groups",
             "members",
             "groupStatus",
             "groupPolicy"
           ]

    compact = json["non_tty_compact_stdout"]
    pretty = json["tty_pretty_stdout"]

    assert compact["add"] ==
             "{\"status\":\"success\",\"groupName\":\"g1\",\"members\":[\"alice\",\"bob\"]}\n"

    assert compact["empty_list"] == "{\"status\":\"success\"}\n"
    assert pretty["empty_list"] == "{\n \"status\": \"success\"\n}\n"

    assert Map.keys(compact) |> Enum.sort() == Map.keys(pretty) |> Enum.sort()

    for {id, compact_stdout} <- compact do
      pretty_stdout = pretty[id]
      assert one_trailing_lf?(compact_stdout)
      assert one_trailing_lf?(pretty_stdout)
      refute String.contains?(String.trim_trailing(compact_stdout, "\n"), "\n")
      assert Jason.decode!(compact_stdout) == Jason.decode!(pretty_stdout)
    end

    assert json["argv"]["add"] |> Enum.take(2) == ["mc", "--json"]
    assert json["modes"]["non_tty"]["globalJSONLine"]
    refute json["modes"]["tty"]["globalJSONLine"]
  end

  @tag :group_request_red
  test "valid G3 body reaches the planned plaintext GroupRequest parser", fixtures do
    request =
      fixtures["madmin_group_wire"]["exact_requests"]
      |> index_by_id()
      |> Map.fetch!("add_fresh_raw_order_duplicates")

    body = request["body"]

    conn =
      :put
      |> Plug.Test.conn("/minio/admin/v3/update-group-members", body)
      |> Plug.Conn.delete_req_header("content-type")
      |> Plug.Conn.delete_req_header("content-length")
      |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))

    assert Plug.Conn.get_req_header(conn, "content-type") == []

    assert {parsed_conn, parsed} =
             apply(Maxio.Admin.GroupRequest, :read_update_body!, [conn])

    assert parsed_conn.state == :unset

    assert parsed == %{
             group: "g1",
             group_status: "",
             members: ["bob", "alice", "bob"],
             remove?: false
           }
  end

  defp index_by_id(entries), do: Map.new(entries, &{&1["id"], &1})

  defp one_trailing_lf?(value) do
    String.ends_with?(value, "\n") and not String.ends_with?(value, "\n\n")
  end
end
