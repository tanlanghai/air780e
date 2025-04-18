--[[
socket客户端演示

提示: 
1. socket支持多个连接的, 通常最多支持8个, 可通过不同的taskName进行区分
2. 支持与http/mqtt/websocket/ftp库同时使用, 互不干扰
3. 支持IP和域名, 域名是自动解析的, 但解析域名也需要耗时
4. 加密连接(TLS/SSL)需要更多内存, 这意味着能容纳的连接数会小很多, 同时也更慢

TLS协议及加密套件
TLS
TLS 1.0 支持
TLS 1.1 支持
TLS 1.2 支持
TLS 1.3 默认未开启, 未测试
SSL 3.0, 默认禁用

加密套件请查询：https://wiki.luatos.com/chips/air780e/network.html#tls

如需使用ipv6, 请查阅 demo/ipv6, 本demo只涉及ipv4
]]

-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "scdemo"
VERSION = "1.0.0"

log.info("main", PROJECT, VERSION)

-- 一定要添加sys.lua !!!!
sys = require("sys")
sysplus = require("sysplus")
libnet = require "libnet"


-- Air780E的AT固件默认会为开机键防抖, 导致部分用户刷机很麻烦
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

if wdt then
    --添加硬狗防止程序卡死，在支持的设备上启用这个功能
    wdt.init(9000)--初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000)--3s喂一次狗
end


--=============================================================
-- 测试网站 https://netlab.luatos.com/ 点击 打开TCP 获取测试端口号
-- 要按实际情况修改
local host = "112.125.89.8" -- 服务器ip或者域名, 都可以的
local port = 45186           -- 服务器端口号
local is_udp = false        -- 如果是UDP, 要改成true, false就是TCP
local is_tls = true        -- 加密与否, 要看服务器的实际情况
--=============================================================

-- 处理未识别的网络消息
local function netCB(msg)
	log.info("未处理消息", msg[1], msg[2], msg[3], msg[4])
end

-- 演示task
local function sockettest()
    -- 等待联网
    sys.waitUntil("IP_READY")

    -- 时间同步
    socket.sntp()

    -- 开始正在的逻辑, 发起socket链接,等待数据/上报心跳
    local taskName = "sc"
    local topic = taskName .. "_txrx"
    log.info("topic", topic)
    local txqueue = {}
    --[[创建一个任务线程
    @param1     function   任务函数名，用于resume唤醒时调用
    @param2     string     任务名称，用于唤醒任务id
    @param3     function   接收到非目标消息时的回调函数
    @param4     any        任务函数fun的可变参数
    @return     number     返回该任务的线程号
    ]]
    sysplus.taskInitEx(sockettask, taskName, netCB, taskName, txqueue, topic)
    while 1 do
        local result, tp, data = sys.waitUntil(topic, 30000)
        log.info("event", result, tp, data)
        if not result then
            -- 等很久了,没数据上传/下发, 发个日期心跳包吧
            table.insert(txqueue, os.date())
            sys_send(taskName, socket.EVENT, 0)
        elseif tp == "uplink" then
            -- 上行数据, 主动上报的数据,那就发送呀
            table.insert(txqueue, data)
            sys_send(taskName, socket.EVENT, 0)
        elseif tp == "downlink" then
            -- 下行数据,接收的数据, 从ipv6task来的
            -- 其他代码可以通过 sys.publish()
            log.info("socket", "收到下发的数据了", #data,"data:",data)
        end
    end
end

function sockettask(d1Name, txqueue, rxtopic)
    -- 打印准备连接的服务器信息
    log.info("socket", host, port, is_udp and "UDP" or "TCP", is_tls and "TLS" or "RAW")

    -- 准备好所需要的接收缓冲区
    local rx_buff = zbuff.create(1024)
    local netc = socket.create(nil, d1Name)
    socket.config(netc, nil, is_udp, is_tls)
    log.info("任务id", d1Name)

    while true do
        -- 连接服务器, 15秒超时
        log.info("socket", "开始连接服务器")
        sysplus.cleanMsg(d1Name)
        local result = libnet.connect(d1Name, 15000, netc, host, port)
        if result then
			log.info("socket", "服务器连上了")
            --向服务器发送数据
			libnet.tx(d1Name, 0, netc, "helloworld")
        else
            log.info("socket", "服务器没连上了!!!")
		end
		while result do
            -- 连接成功之后, 先尝试接收
            -- log.info("socket", "调用rx接收数据")
			local succ, param = socket.rx(netc, rx_buff)
			if not succ then
				log.info("服务器断开了", succ, param, ip, port)
				break
			end
            -- 如果服务器有下发数据, used()就必然大于0, 进行处理
			if rx_buff:used() > 0 then
				log.info("socket", "收到服务器数据，长度", rx_buff:used())
                local data = rx_buff:query() -- 获取数据
                sys.publish(rxtopic, "downlink", data)
				rx_buff:del()
			end
            -- log.info("libnet", "调用wait开始等待消息")
            -- 等待事件, 例如: 服务器下发数据, 有数据准备上报, 服务器断开连接
			result, param, param2 = libnet.wait(d1Name, 15000, netc)
            log.info("libnet", "wait", result, param, param2)
			if not result then
                -- 网络异常了, 那就断开了, 执行清理工作
				log.info("socket", "服务器断开了", result, param)
				break
            elseif #txqueue > 0 then
                -- 有待上报的数据,处理之
                while #txqueue > 0 do
                    local data = table.remove(txqueue, 1)
                    if not data then
                        break
                    end
                    result,param = libnet.tx(d1Name, 15000, netc,data)
                    log.info("libnet", "发送数据的结果", result, param)
                    if not result then
                        log.info("socket", "数据发送异常", result, param)
                        break
                    end
                end
            end
            -- 循环尾部, 继续下一轮循环
		end
        -- 能到这里, 要么服务器断开连接, 要么上报(tx)失败, 或者是主动退出
		libnet.close(d1Name, 5000, netc)
		-- log.info(rtos.meminfo("sys"))
		sys.wait(30000) -- 这是重连时长, 自行调整
    end
end

sys.taskInit(sockettest)

-- 演示定时上报数据, 不需要就注释掉
sys.taskInit(function()
    sys.wait(5000)
    while 1 do
        sys.publish("sc_txrx", "uplink", os.date())
        sys.wait(10000)
    end
end)

-- 演示uart数据上报, 不需要就注释掉
if rtos.bsp() == "EC618" then
    uart.setup(1, 115200) -- 注意, 是UART1, 不是虚拟串口, 演示目的
    uart.on(1, "receive", function(id, len)
        while 1 do
            local s = uart.read(1, 1024)
            if #s == 0 then
                break
            end
            sys.publish("sc_txrx", "uplink", s)
            if #s == len then
                break
            end
        end
    end)
end

-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!

