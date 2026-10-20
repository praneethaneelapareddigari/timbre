defmodule TimbreWeb.RecordingControllerTest do
  use TimbreWeb.ConnCase

  alias Timbre.Recordings

  defp upload(contents, content_type \\ "audio/webm") do
    path = Path.join(System.tmp_dir!(), "timbre-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "clip.webm", content_type: content_type}
  end

  defp create!(data \\ "0123456789") do
    {:ok, rec} =
      Recordings.create_recording(%{title: "clip", mime_type: "audio/webm", data: data})

    rec
  end

  describe "POST /api/recordings" do
    test "saves an uploaded clip", %{conn: conn} do
      conn =
        post(conn, ~p"/api/recordings", %{
          "audio" => upload("RIFFfake"),
          "title" => "Hello",
          "duration_ms" => "1500"
        })

      assert %{"id" => id, "title" => "Hello", "duration_ms" => 1500, "byte_size" => 8} =
               json_response(conn, 201)["data"]

      assert {:ok, "audio/webm", "RIFFfake"} = Recordings.fetch_audio(id)
    end

    test "stores processed clips with their effect chain", %{conn: conn} do
      source = create!()

      conn =
        post(conn, ~p"/api/recordings", %{
          "audio" => upload("wav", "audio/wav"),
          "title" => "Processed",
          "kind" => "processed",
          "source_recording_id" => to_string(source.id),
          "effects" => Jason.encode!([%{id: "echo", delay_ms: 250}])
        })

      data = json_response(conn, 201)["data"]
      assert data["kind"] == "processed"
      assert data["source_recording_id"] == source.id
      assert data["effects"] == [%{"id" => "echo", "delay_ms" => 250}]
    end

    test "defaults the title when none is given", %{conn: conn} do
      conn = post(conn, ~p"/api/recordings", %{"audio" => upload("x")})
      assert "Recording " <> _ = json_response(conn, 201)["data"]["title"]
    end

    test "rejects non-audio uploads", %{conn: conn} do
      conn = post(conn, ~p"/api/recordings", %{"audio" => upload("x", "text/plain")})
      assert %{"mime_type" => _} = json_response(conn, 422)["errors"]
    end

    test "rejects a request without a file", %{conn: conn} do
      conn = post(conn, ~p"/api/recordings", %{"title" => "nothing"})
      assert json_response(conn, 400)
    end
  end

  test "GET /api/recordings lists recordings with playback urls", %{conn: conn} do
    rec = create!()
    assert [item] = json_response(get(conn, ~p"/api/recordings"), 200)["data"]
    assert item["id"] == rec.id
    assert item["audio_url"] == "/api/recordings/#{rec.id}/audio"
    refute Map.has_key?(item, "data")
  end

  describe "GET /api/recordings/:id/audio" do
    test "serves the full file", %{conn: conn} do
      rec = create!()
      conn = get(conn, ~p"/api/recordings/#{rec.id}/audio")
      assert response(conn, 200) == "0123456789"
      assert get_resp_header(conn, "content-type") == ["audio/webm"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "honours byte ranges", %{conn: conn} do
      rec = create!()

      conn =
        conn |> put_req_header("range", "bytes=2-4") |> get(~p"/api/recordings/#{rec.id}/audio")

      assert response(conn, 206) == "234"
      assert get_resp_header(conn, "content-range") == ["bytes 2-4/10"]

      open =
        build_conn()
        |> put_req_header("range", "bytes=7-")
        |> get(~p"/api/recordings/#{rec.id}/audio")

      assert response(open, 206) == "789"

      suffix =
        build_conn()
        |> put_req_header("range", "bytes=-2")
        |> get(~p"/api/recordings/#{rec.id}/audio")

      assert response(suffix, 206) == "89"

      bad =
        build_conn()
        |> put_req_header("range", "bytes=50-60")
        |> get(~p"/api/recordings/#{rec.id}/audio")

      assert response(bad, 416) == ""
    end

    test "404s for unknown ids", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/recordings/999999/audio"), 404)
    end
  end

  test "PATCH renames, DELETE removes", %{conn: conn} do
    rec = create!()
    conn = patch(conn, ~p"/api/recordings/#{rec.id}", %{"title" => "New name"})
    assert json_response(conn, 200)["data"]["title"] == "New name"

    conn = delete(build_conn(), ~p"/api/recordings/#{rec.id}")
    assert response(conn, 204)
    assert Recordings.get_recording(rec.id) == nil
  end

  test "transcribe reports when no API key is configured", %{conn: conn} do
    previous = Application.get_env(:timbre, :openai_api_key)
    Application.put_env(:timbre, :openai_api_key, nil)
    on_exit(fn -> Application.put_env(:timbre, :openai_api_key, previous) end)

    rec = create!()
    conn = post(conn, ~p"/api/recordings/#{rec.id}/transcribe")
    assert json_response(conn, 503)["errors"]["detail"] =~ "OPENAI_API_KEY"
  end

  test "POST /api/sessions mints a share code", %{conn: conn} do
    assert %{"code" => code, "sample_rate" => 24_000} =
             json_response(post(conn, ~p"/api/sessions"), 201)["data"]

    assert Timbre.Sessions.valid_code?(code)

    assert %{"code" => ^code, "status" => "idle"} =
             json_response(get(build_conn(), ~p"/api/sessions/#{code}"), 200)["data"]
  end
end
