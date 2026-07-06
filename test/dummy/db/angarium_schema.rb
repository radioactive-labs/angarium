# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_06_035322) do
  create_table "angarium_deliveries", force: :cascade do |t|
    t.integer "attempt_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "endpoint_id", null: false
    t.bigint "event_id", null: false
    t.datetime "last_attempt_at"
    t.datetime "next_attempt_at"
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint_id"], name: "index_angarium_deliveries_on_endpoint_id"
    t.index ["event_id"], name: "index_angarium_deliveries_on_event_id"
  end

  create_table "angarium_delivery_attempts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "delivery_id", null: false
    t.float "duration"
    t.string "error"
    t.text "response_body"
    t.integer "response_code"
    t.datetime "updated_at", null: false
    t.index ["delivery_id"], name: "index_angarium_delivery_attempts_on_delivery_id"
  end

  create_table "angarium_endpoints", force: :cascade do |t|
    t.boolean "allow_private_network", default: false, null: false
    t.json "allowed_networks", default: [], null: false
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.json "custom_headers"
    t.string "name", null: false
    t.string "owner_id", null: false
    t.string "owner_type", null: false
    t.text "previous_signing_secret"
    t.datetime "secret_rotated_at"
    t.text "signing_secret", null: false
    t.string "status", default: "enabled", null: false
    t.datetime "status_changed_at"
    t.json "subscribed_events", default: [], null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["owner_type", "owner_id"], name: "index_angarium_endpoints_on_owner"
  end

  create_table "angarium_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.json "payload", default: {}, null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "angarium_deliveries", "angarium_endpoints", column: "endpoint_id"
  add_foreign_key "angarium_deliveries", "angarium_events", column: "event_id"
  add_foreign_key "angarium_delivery_attempts", "angarium_deliveries", column: "delivery_id"
end
