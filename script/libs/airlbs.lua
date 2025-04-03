--[[
@module airlbs
@summary airlbs 定位服务(收费服务，需自行联系销售申请)
@version 1.0
@date    2024.11.01
@author  Dozingfiretruck
@usage
--注意:因使用了sys.wait()所有api需要在协程中使用
--注意:使用前需同步时间
-- 用法实例
local airlbs = require "airlbs"

sys.taskInit(function()
    sys.waitUntil("IP_READY")

    socket.sntp()
    sys.waitUntil("NTP_UPDATE", 1000)

    while 1 do
        local result , data = airlbs.request({project_id = "xxx",project_key = 'xxx',timeout = 1000})
        if result then
            print("airlbs", json.encode(data))
        end
        sys.wait(20000)
    end

end)
]] sys = require("sys")
sysplus = require("sysplus")
libnet = require "libnet"

local airlbs_host = "airlbs.openluat.com"
local airlbs_port = 12413

local lib_name = "airlbs"
local lib_topic = lib_name .. "topic"

local location_data = 0
local disconnect = -1
local airlbs_timeout = 15000

local airlbs = {}

local function airlbs_task(task_name, buff, timeout)
    local netc = socket.create(nil, lib_name)
    socket.config(netc, nil, true) -- udp

    sysplus.cleanMsg(lib_name)
    local result = libnet.connect(lib_name, 15000, netc, airlbs_host, airlbs_port)
    if result then
        log.info(lib_name, "服务器连上了")
        libnet.tx(lib_name, 0, netc, buff)
    else
        log.info(lib_name, "服务器没连上了!!!")
        sys.publish(lib_topic, disconnect)
        libnet.close(lib_name, 5000, netc)
        return
    end
    buff:del()
    while result do
        local succ, param = socket.rx(netc, buff)
        if not succ then
            log.error(lib_name, "服务器断开了", succ, param)
            sys.publish(lib_topic, disconnect)
            break
        end
        if buff:used() > 0 then
            local location = nil
            local data = buff:query(0, 1) -- 获取数据
            if data:toHex() == '00' then
                location = json.decode(buff:query(1))
            else
                log.error(lib_name, "not json data")
            end
            sys.publish(lib_topic, location_data, location)
            buff:del()
            break
        end
        result, param, param2 = libnet.wait(lib_name, timeout, netc)
        log.info(lib_name, "wait", result, param, param2)
        if param == false then
            log.error(lib_name, "服务器断开了", succ, param)
            sys.publish(lib_topic, disconnect)
            break
        end
    end
    libnet.close(lib_name, 5000, netc)
end

-- 处理未识别的网络消息
local function netCB(msg)
    log.info("未处理消息", msg[1], msg[2], msg[3], msg[4])
end

--[[
获取定位数据
@api airlbs.request(param)
@param table 参数(联系销售获取id与key) project_id:项目ID project_key:项目密钥 timeout:超时时间,单位毫秒 默认15000
@return bool 成功返回true,失败会返回false
@return table 定位成功生效，成功返回定位数据
@usage
local result , data = airlbs.request({project_id = airlbs_project_id,project_key = airlbs_project_key})
if result then
    print("airlbs", json.encode(data))
end
]]
function airlbs.request(param)
    if not mobile then
        log.error(lib_name, "no mobile")
        return false
    end
    if mobile.status() == 0 then
        log.error(lib_name, "网络未注册")
        return false
    end
    if param.project_id == nil or param.project_key == nil then
        log.error(lib_name, "param error")
        return false
    end

    local udp_buff = zbuff.create(1500)
    local auth_type = 0x01
    local lbs_data_type = 0x00
    local project_id = param.project_id
    if project_id:len() ~= 6 then
        log.error("airlbs", "project_id len not 6")
    end
    local imei = mobile.imei()
    local muid = mobile.muid()
    local timestamp = os.time()
    local project_key = param.project_key
    local nonce = crypto.trng(6)
    local hmac_data = crypto.hmac_sha1(project_id .. imei .. muid .. timestamp .. nonce, project_key)
    -- log.debug(lib_name,"hmac_sha1", hmac_data)

    mobile.reqCellInfo(60)
    sys.waitUntil("CELL_INFO_UPDATE", param.timeout or airlbs_timeout)
    -- log.info("cell", json.encode(mobile.getCellInfo()))

    local lbs_data = {
        cells = {}
    }
    for k, v in pairs(mobile.getCellInfo()) do
        lbs_data.cells[k] = {}
        lbs_data.cells[k][1] = v.mcc
        lbs_data.cells[k][2] = v.mnc
        lbs_data.cells[k][3] = v.tac
        lbs_data.cells[k][4] = v.cid
        lbs_data.cells[k][5] = v.rssi
        lbs_data.cells[k][6] = v.snr
        lbs_data.cells[k][7] = v.pci
        lbs_data.cells[k][8] = v.rsrp
        lbs_data.cells[k][9] = v.rsrq
        lbs_data.cells[k][10] = v.earfcn
    end
    if param.wifi_info and #param.wifi_info > 0 then
        lbs_data.macs = {}
        for k, v in pairs(param.wifi_info) do
            lbs_data.macs[k] = {}
            lbs_data.macs[k][1] = v.bssid:toHex():gsub("(%x%x)", "%1:"):sub(1, -2)
            lbs_data.macs[k][2] = v.rssi
        end
    end
    local lbs_jdata = json.encode(lbs_data)
    log.info("扫描出的数据",lbs_jdata)
    udp_buff:write(string.char(auth_type) .. project_id .. imei .. muid .. timestamp .. nonce .. hmac_data:fromHex() .. string.char(lbs_data_type) .. lbs_jdata)

    sysplus.taskInitEx(airlbs_task, lib_name, netCB, lib_name, udp_buff, param.timeout or airlbs_timeout)

    while 1 do
        local result, tp, data = sys.waitUntil(lib_topic, param.timeout or airlbs_timeout)
        log.info("定位请求的结果", result, "超时时间", tp, data)
        if not result then
            return false, "timeout"
        elseif tp == location_data then
            if not data then
                log.error(lib_name, "无数据, 请检查project_id和project_key")
                return false
                -- data.result 0-找不到 1-成功 2-qps超限 3-欠费 4-其他错误 
            elseif data.result == 0 then
                log.error(lib_name, "no location(基站定位服务器查询当前地址失败)")
                return false
            elseif data.result == 1 then
                log.info("多基站请求成功,服务器返回的原始数据", data)
                return true, {
                    lng = data.lng,
                    lat = data.lat
                }
            elseif data.result == 2 then
                log.error(lib_name, "qps limit(当前请求已到达限制,请检查当前请求是否过于频繁))")
                return false
            elseif data.result == 3 then
                log.error(lib_name, "当前设备已欠费,请联系销售充值")
                return false
            elseif data.result == 4 then
                log.error(lib_name, "other error")
                return false
            else
                log.error("其他错误,错误码", data.result, lib_name)
            end
        else
            log.error(lib_name, "net error")
            return false
        end
    end

end

return airlbs

