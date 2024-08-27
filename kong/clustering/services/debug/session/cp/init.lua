local _M = {}


local function rpc_consume_data(_node_id, data)
  print("_node_id = " .. require("inspect")(_node_id))
  print("FROM THE RPC CALL data = " .. require("inspect")(data))
  return true
end

local function start_kong_debug(plugin_config)

end


function _M.init(manager)
  manager.callbacks:register("kong.debug.session.v1.ingest", rpc_consume_data)
end

return _M
