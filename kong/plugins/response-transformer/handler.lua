-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local body_transformer = require "kong.plugins.response-transformer.body_transformer"
local header_transformer = require "kong.plugins.response-transformer.header_transformer"
local kong_meta = require "kong.meta"


local is_body_transform_set = header_transformer.is_body_transform_set
local is_json_body = header_transformer.is_json_body
local kong = kong


local ResponseTransformerHandler = {
  PRIORITY = 800,
  VERSION = kong_meta.core_version,
}


function ResponseTransformerHandler:header_filter(conf)
  header_transformer.transform_headers(conf, kong.response.get_headers())
end


function ResponseTransformerHandler:body_filter(conf)

  if not is_body_transform_set(conf)
    or not is_json_body(kong.response.get_header("Content-Type"))
  then
    return
  end

  local body = kong.response.get_raw_body()

  local json_body, err = body_transformer.transform_json_body(conf, body)
  if err then
    kong.log.warn("body transform failed: " .. err)
    return
  end
  return kong.response.set_raw_body(json_body)
end


return ResponseTransformerHandler
