require "test_helper"

class Angarium::EventTest < ActiveSupport::TestCase
  test "payload defaults to {} at the model layer" do
    # The payload column carries no DB default (MySQL forbids defaults on JSON
    # columns), so the model supplies it to satisfy null: false on insert.
    event = Angarium::Event.new(name: "invoice.paid")
    assert_equal({}, event.payload)
    event.save!
    assert_equal({}, event.reload.payload)
  end

  test "each event gets its own default payload, not a shared one" do
    a = Angarium::Event.new
    b = Angarium::Event.new
    a.payload["x"] = 1
    assert_equal({}, b.payload, "the default must not be shared across records")
  end
end
