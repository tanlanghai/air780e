--[[
@module lbsLoc2
@summary 基站定位v2
@version 1.0
@date    2023.5.23
@author  wendal
@demo    lbsLoc2
@usage
-- 注意:
-- 1. 因使用了sys.wait()所有api需要在协程中使用
-- 2. 仅支持单基站定位, 即当前联网的基站
-- 3. 本服务当前处于测试状态
sys.taskInit(function()
    sys.waitUntil("IP_READY", 30000)
    -- mobile.reqCellInfo(60)
    -- sys.wait(1000)
    while mobile do -- 没有mobile库就没有基站定位
        mobile.reqCellInfo(15)
        sys.waitUntil("CELL_INFO_UPDATE", 3000)
        local lat, lng, t = lbsLoc2.request(5000)
        -- local lat, lng, t = lbsLoc2.request(5000, "bs.openluat.com")
        log.info("lbsLoc2", lat, lng, (json.encode(t or {})))
        sys.wait(60000)
    end
end)
]]

local sys = require "sys"

local lbsLoc2 = {}

local function numToBcdNum(inStr,destLen)
    local l,t,num = string.len(inStr or ""),{}
    destLen = destLen or (inStr:len()+1)/2
    for i=1,l,2 do
        num = tonumber(inStr:sub(i,i+1),16)
        if i==l then
            num = 0xf0+num
        else
            num = (num%0x10)*0x10 + (num-(num%0x10))/0x10
        end
        table.insert(t,num)
    end

    local s = string.char(unpack(t))

    l = string.len(s)
    if l < destLen then
        s = s .. string.rep("\255",destLen-l)
    elseif l > destLen then
        s = string.sub(s,1,destLen)
    end

    return s
end

--- BCD编码格式字符串 转化为 号码ASCII字符串(仅支持数字)
-- @string num 待转换字符串
-- @return string data,转换后的字符串
-- @usage
local function bcdNumToNum(num)
	local byte,v1,v2
	local t = {}

	for i=1,num:len() do
		byte = num:byte(i)
		v1,v2 = bit.band(byte,0x0f),bit.band(bit.rshift(byte,4),0x0f)

		if v1 == 0x0f then break end
		table.insert(t,v1)

		if v2 == 0x0f then break end
		table.insert(t,v2)
	end

	return table.concat(t)
end

lbsLoc2.imei = numToBcdNum(mobile.imei())

local function enCellInfo(s)
    -- 改造成单基站, 反正服务器也只认单基站
    local v = s[1]
    log.info("cell", json.encode(v))
    local ret = pack.pack(">HHbbi",v.tac,v.mcc,v.mnc,31,v.cid)
    return string.char(1)..ret
end

local function trans(str)
    local s = str
    if str:len()<10 then
        s = str..string.rep("0",10-str:len())
    end

    return s:sub(1,3).."."..s:sub(4,10)
end

--[[
执行定位请求
@api lbsLoc2.request(timeout, host, port, reqTime)
@number 请求超时时间,单位毫秒,默认15000
@number 服务器地址,有默认值,可以是域名,一般不需要填
@number 服务器端口,默认12411,一般不需要填
@bool   是否要求返回服务器时间
@return string  若成功,返回定位坐标的纬度,否则会返还nil
@return string  若成功,返回定位坐标的精度,否则会返还nil
@return table   服务器时间,东八区时间. 当reqTime为true且定位成功才会返回
@usage
-- 关于坐标系
-- 部分情况下会返回GCJ02坐标系, 部分情况返回的是WGS84坐标
-- 历史数据已经无法分辨具体坐标系
-- 鉴于两种坐标系之间的误差并不大,小于基站定位本身的误差, 纠偏的意义不大
sys.taskInit(function()
    sys.waitUntil("IP_READY", 30000)
    -- mobile.reqCellInfo(60)
    -- sys.wait(1000)
    while mobile do -- 没有mobile库就没有基站定位
        mobile.reqCellInfo(15)
        sys.waitUntil("CELL_INFO_UPDATE", 3000)
        local lat, lng, t = lbsLoc2.request(5000)
        -- local lat, lng, t = lbsLoc2.request(5000, "bs.openluat.com")
        log.info("lbsLoc2", lat, lng, (json.encode(t or {})))
        sys.wait(60000)
    end
end)
]]
function lbsLoc2.request(timeout, host, port, reqTime)
    if mobile.status() == 0 then
        return
    end
    local hosts = host and {host} or {"free.bs.air32.cn", "bs.openluat.com"}
    port = port and tonumber(port) or 12411
    local sc = socket.create(nil, function(sc, event)
        -- log.info("lbsLoc", "event", event, socket.ON_LINE, socket.TX_OK, socket.EVENT)
        if event == socket.ON_LINE then
            --log.info("lbsLoc", "已连接")
            sys.publish("LBS_CONACK")
        elseif event == socket.TX_OK then
            --log.info("lbsLoc", "发送完成")
            sys.publish("LBS_TX")
        elseif event == socket.EVENT then
            --log.info("lbsLoc", "有数据来")
            sys.publish("LBS_RX")
        end
    end)
    if sc == nil then
        return
    end
    -- socket.debug(sc, true)
    socket.config(sc, nil, true)
    local rxbuff = zbuff.create(64)
    for k, rhost in pairs(hosts) do
        local reqStr = string.char(0, (reqTime and 4 or 0) +8) .. lbsLoc2.imei
        local tmp = nil
        if mobile.scell then
            local scell = mobile.scell()
            if scell and scell.mcc then
                -- log.debug("lbsLoc2", "使用当前驻网基站的信息")
                tmp = pack.pack(">bHHbbi", 1, scell.tac, scell.mcc, scell.mnc, 31, scell.eci)
            end
        end
        if tmp == nil then
            local cells = mobile.getCellInfo()
            if cells == nil or #cells == 0 then
                socket.release(sc)
                return
            end
            reqStr = reqStr .. enCellInfo(cells)
        else
            reqStr = reqStr .. tmp
        end
        -- log.debug("lbsLoc2", "待发送数据", (reqStr:toHex()))
        log.debug("lbsLoc2", rhost, port)
        if socket.connect(sc, rhost, port) and sys.waitUntil("LBS_CONACK", 1000) then
            if socket.tx(sc, reqStr) and sys.waitUntil("LBS_TX", 1000) then
                socket.wait(sc)
                if sys.waitUntil("LBS_RX", timeout or 15000) then
                    local succ, data_len = socket.rx(sc, rxbuff)
                    -- log.debug("lbsLoc", "rx", succ, data_len)
                    if succ and data_len > 0 then
                        socket.close(sc)
                        break
                    else
                        log.debug("lbsLoc", "rx数据失败", rhost)
                    end
                else
                    log.debug("lbsLoc", "等待数据超时", rhost)
                end
            else
                log.debug("lbsLoc", "tx调用失败或TX_ACK超时", rhost)
            end
        else
            log.debug("lbsLoc", "connect调用失败或CONACK超时", rhost)
        end
        socket.close(sc)
        --sys.wait(100)
    end
    sys.wait(100)
    socket.release(sc)
    if rxbuff:used() > 0 then
        local resp = rxbuff:toStr(0, rxbuff:used())
        log.debug("lbsLoc2", "rx", (resp:toHex()))
        if resp:len() >= 11 and(resp:byte(1) == 0 or resp:byte(1) == 0xFF) then
            local lat = trans(bcdNumToNum(resp:sub(2, 6)))
            local lng = trans(bcdNumToNum(resp:sub(7, 11)))
            local t = nil
            if resp:len() >= 17 then
                t = {
                    year=resp:byte(12) + 2000,
                    month=resp:byte(13),
                    day=resp:byte(14),
                    hour=resp:byte(15),
                    min=resp:byte(16),
                    sec=resp:byte(17),
                }
            end
            return lat, lng, t
        end
    end
    rxbuff:del()
end

return lbsLoc2
