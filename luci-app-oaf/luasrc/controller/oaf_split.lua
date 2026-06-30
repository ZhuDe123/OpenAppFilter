local utl = require "luci.util"

function index()
	entry({"admin", "network", "oaf_split_clear_dev"},
		call("clear_dev_time"), nil).leaf = true
end

function clear_dev_time()
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")

	local mac = luci.http.formvalue("mac")
	local req_obj = { action = "clear_active_time" }
	if mac and mac ~= "" then
		-- 简单 MAC 格式校验：应为 17 字符的 XX:XX:XX:XX:XX:XX
		if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			req_obj.mac = mac
		else
			luci.http.write_json({ code = -1, message = "Invalid MAC address format" })
			return
		end
	end

	local resp_obj = utl.ubus("appfilter", "cmd", req_obj)
	if not resp_obj then
		luci.http.write_json({ code = -1, message = "UBUS call failed" })
		return
	end
	luci.http.write_json(resp_obj)
end
