require "test_helper"

class Angarium::ClientTest < ActiveSupport::TestCase
  # These exercise the real Client against WebMock. We deliberately do NOT pin
  # the connection (no :addresses), so httpx's WebMock adapter mocks cleanly
  # without the pinned-socket teardown hang documented in test_helper.
  test "truncates the stored response body to max_response_body_bytes" do
    stub_request(:post, "https://example.test/hook").to_return(status: 200, body: "x" * 100)

    Angarium.config.stub(:max_response_body_bytes, 10) do
      result = Angarium::Client.new.post("https://example.test/hook", body: "{}", headers: {})
      assert result.success?
      assert_operator result.body.bytesize, :<=, 10
    end
  end

  test "stores the full body when max_response_body_bytes is nil" do
    stub_request(:post, "https://example.test/hook").to_return(status: 200, body: "y" * 100)

    Angarium.config.stub(:max_response_body_bytes, nil) do
      result = Angarium::Client.new.post("https://example.test/hook", body: "{}", headers: {})
      assert_equal 100, result.body.bytesize
    end
  end

  test "populates downcased response headers on success" do
    stub_request(:post, "https://example.test/hook")
      .to_return(status: 200, body: "ok", headers: { "Retry-After" => "30", "Content-Type" => "text/plain" })

    result = Angarium::Client.new.post("https://example.test/hook", body: "{}", headers: {})
    assert_equal "30", result.headers["retry-after"]
    assert_equal "text/plain", result.headers["content-type"]
  end

  test "error responses carry an empty headers hash" do
    stub_request(:post, "https://example.test/hook").to_timeout

    result = Angarium::Client.new.post("https://example.test/hook", body: "{}", headers: {})
    refute result.success?
    assert_equal({}, result.headers)
  end
end
