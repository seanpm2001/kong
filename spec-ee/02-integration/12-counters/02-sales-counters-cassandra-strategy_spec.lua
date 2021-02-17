-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local utils = require "kong.tools.utils"
local cassandra_strategy = require("kong.counters.sales.strategies.cassandra")

local LICENSE_DATA_TNAME = "license_data"

local license_strategies = {
  "licensed",
  "unlicensed",
}

local function get_license_creation_date(license_strategy)
  local date = "2019-03-03"
  if license_strategy == "licensed" then
    date = tostring(os.date("%Y-%d-%m"))
  end

  local date_split = utils.split(date, "-")
  local date_in_sec = os.time({
    year = date_split[1],
    month = date_split[2],
    day = date_split[3],
  })
  return date, date_in_sec
end

local ffi = require('ffi')
ffi.cdef([[
  int unsetenv(const char* name);
]])

for _, strategy in helpers.each_strategy({"cassandra"}) do
  for _, license_strategy in ipairs(license_strategies) do
    describe("sales counters strategy #" .. strategy .. " for #" .. license_strategy .. " Kong", function()
      local strategy
      local cluster
      local db
      local uuid
      local snapshot


      setup(function()
        if license_strategy == license_strategies.unlicensed then
          ffi.C.unsetenv("KONG_LICENSE_DATA")
          ffi.C.unsetenv("KONG_LICENSE_PATH")
        end

        db = select(2, helpers.get_db_utils(strategy))
        strategy = cassandra_strategy:new(db)
        db = db.connector
        cluster  = db.cluster
        uuid     = utils.uuid()
      end)


      before_each(function()
        snapshot = assert:snapshot()
        cluster:execute("TRUNCATE " .. LICENSE_DATA_TNAME)
      end)

      after_each(function()
        snapshot:revert()
      end)


      teardown(function()
        cluster:execute("TRUNCATE " .. LICENSE_DATA_TNAME)
      end)

      describe(":insert_stats()", function()
        it("should flush data to cassandra from one node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = uuid
          }

          strategy:flush_data(data)

          local res, _ = cluster:execute("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = " .. tostring(data.node_id)
            .. " AND license_creation_date = " .. select(2, get_license_creation_date(license_strategy)) * 1000)

          local expected_data = {
              node_id  = uuid,
              license_creation_date = select(2, get_license_creation_date(license_strategy)) * 1000,
              req_cnt = 10
          }

          assert.same(expected_data, res[1])
        end)

        it("should flush data to cassandra with more than one row from node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = uuid
          }

          strategy:flush_data(data)

          local res, _ = cluster:execute("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = " .. tostring(data.node_id))

          local expected_data = {
            node_id  = uuid,
            license_creation_date = select(2, get_license_creation_date(license_strategy)) * 1000,
            req_cnt = 10
          }

          assert.same(expected_data, res[1])

          local data = {
            request_count = 269,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = uuid
          }

          strategy:flush_data(data)

          res, _ = cluster:execute("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = " .. tostring(data.node_id))

          local expected_data = {
            node_id  = uuid,
            license_creation_date = select(2, get_license_creation_date(license_strategy)) * 1000,
            req_cnt = 279
          }

          assert.same(expected_data, res[1])
        end)

        it("should flush data to cassandra from more than one node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          local res, _ = cluster:execute("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = " .. tostring(data.node_id))

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = select(2, get_license_creation_date(license_strategy)) * 1000,
            req_cnt = 10
          }

          assert.same(expected_data, res[1])

          local data = {
            request_count = 58,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          res, _ = cluster:execute("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = " .. tostring(data.node_id))

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = select(2, get_license_creation_date(license_strategy)) * 1000,
            req_cnt = 58
          }

          assert.same(expected_data, res[1])
        end)
      end)
    end)
  end
end
