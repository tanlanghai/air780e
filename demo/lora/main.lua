--- 模块功能：lorademo
-- @module lora
-- @author Dozingfiretruck
-- @release 2021.06.17

-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "lorademo"
VERSION = "1.0.0"

log.info("main", PROJECT, VERSION)

-- sys库是标配
_G.sys = require("sys")

--添加硬狗防止程序卡死
if wdt then
    wdt.init(9000)--初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000)--3s喂一次狗
end

-- spi_id,pin_cs,pin_reset,pin_busy,pin_dio1
local function lora_pin()
    return 0,8,1,18,19
end

local spi_id,pin_cs,pin_reset,pin_busy,pin_dio1 = lora_pin() 

sys.subscribe("LORA_TX_DONE", function()
    lora.recive(1000)
end)

sys.subscribe("LORA_RX_DONE", function(data, size)
    log.info("LORA_RX_DONE: ", data, size)
    lora.send("PING")
end)

sys.subscribe("LORA_RX_TIMEOUT", function()
    lora.recive(1000)
end)

sys.taskInit(function()
    lora.init("llcc68",{id = spi_id,cs = pin_cs,res = pin_reset,busy = pin_busy,dio1 = pin_dio1})
    
    lora.set_channel(433000000)
    lora.set_txconfig("llcc68",
    {mode=1,power=22,fdev=0,bandwidth=0,datarate=9,coderate=4,preambleLen=8,
        fixLen=false,crcOn=true,freqHopOn=0,hopPeriod=0,iqInverted=false,timeout=3000}
    )
    lora.set_rxconfig("llcc68",
    {mode=1,bandwidth=0,datarate=9,coderate=4,bandwidthAfc=0,preambleLen=8,symbTimeout=0,fixLen=false,
        payloadLen=0,crcOn=true,freqHopOn=0,hopPeriod=0,iqInverted=false,rxContinuous=false}
    )

    lora.send("PING")
    while 1 do
        sys.wait(1000)
    end
end)

-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!


