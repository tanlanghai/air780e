--[[
@module xmodem
@summary xmodem 驱动
@version 1.0
@date    2022.06.01
@author  Dozingfiretruck
@usage
--注意:因使用了sys.wait()所有api需要在协程中使用
-- 用法实例
local xmodem = require "xmodem"
sys.taskInit(function()
    xmodem.send(2,115200,"/luadb/test.bin")
    while 1 do
        sys.wait(1000)
    end
end)
]]
local xmodem = {}

local sys = require "sys"

local HEAD
local DATA_SIZE 

local SOH           =   0x01    -- Modem数据头 128
local STX           =   0x02    -- Modem数据头 1K
local EOT           =   0x04    -- 发送结束
local ACK           =   0x06    -- 应答
local NAK           =   0x15    -- 非应答
local CAN           =   0x18    -- 取消发送
local CTRLZ         =   0x1A    -- 填充
local CRC_CHR       =   0x43    -- C: ASCII字符C
local CRC_SIZE      =   2
local FRAME_ID_SIZE =   2
local DATA_SIZE_SOH =   128
local DATA_SIZE_STX =   1024

local function uart_cb(id, len)
    local data = uart.read(id, 1024)
    if #data == 0 then
        return
    end
    log.info("xmodem", "uart读取到数据:", data:toHex())
    data = data:byte(1)
    sys.publish("xmodem", data)
end

--[[
xmodem 发送文件
@api xmodem.send(uart_id, uart_br, file_path,type)
@number uart_id uart端口号
@number uart_br uart波特率
@string file_path 文件路径
@bool type 1k/128 默认1k
@return bool 发送结果
@usage
xmodem.send(2,115200,"/luadb/test.bin")
]]

function xmodem.send(uart_id, uart_br, file_path, type)
    local ret, flen, cnt, crc

    if type then
        HEAD = SOH
        DATA_SIZE = DATA_SIZE_SOH
    else
        HEAD = STX
        DATA_SIZE = DATA_SIZE_STX
    end
    local XMODEM_SIZE = 1+FRAME_ID_SIZE+DATA_SIZE+CRC_SIZE
    local packsn = 0
    local xmodem_buff = zbuff.create(XMODEM_SIZE)
    local data_buff = zbuff.create(DATA_SIZE)
    local fd = io.open(file_path, "rb")
    if fd then
        uart.setup(uart_id,uart_br)
        uart.on(uart_id, "receive", uart_cb)
        local result, data = sys.waitUntil("xmodem", 12000)
        if result and (data == CRC_CHR or data == NAK) then
            cnt = 1
            while true do
                data_buff:set(0, CTRLZ)
                ret, flen = fd:fill(data_buff,0,DATA_SIZE)
                log.info("xmodem", "发送第", cnt, "包")
                if flen > 0 then
                    data_buff:seek(0)
                    crc = crypto.crc16("XMODEM",data_buff)
                    packsn = (packsn+1) & 0xff
                    xmodem_buff[0] = 0x02
                    xmodem_buff[1] = packsn
                    xmodem_buff[2] = 0xff-xmodem_buff[1]
                    data_buff:seek(DATA_SIZE)
                    xmodem_buff:copy(3, data_buff)
                    xmodem_buff[1027] = crc>>8
                    xmodem_buff[1028] = crc&0xff
                    xmodem_buff:seek(XMODEM_SIZE)
                    -- log.info(xmodem_buff:used())
                    :: RESEND ::
                    uart.tx(uart_id, xmodem_buff)
                    result, data = sys.waitUntil("xmodem", 10000)
                    if result and data == ACK then
                        cnt = cnt + 1
                    elseif result and data == NAK then
                        goto RESEND
                    else
                        log.info("xmodem", "发送失败")
                        return false
                    end
                    if flen ~= DATA_SIZE then
                        log.info("xmodem", "文件到头了")
                        break
                    end
                else
                    log.info("xmodem", "文件到头了")
                    break
                end
            end
            uart.write(uart_id, string.char(EOT))
            fd:close()
            return true
        else
            log.info("xmodem", "不支持的起始数据包",data)
            return false
        end
    else
        log.info("xmodem", "待传输的文件不存在")
        return false
    end
end

--[[
关闭xmodem
@api xmodem.close(uart_id)
@number uart_id uart端口号
@usage
-- 执行xmodem传输后, 无论是否传输成功, 都建议关闭xmodem上下文, 也会关闭uart
xmodem.close(2)
]]
function xmodem.close(uart_id)
    uart.on(uart_id, "receive")
    uart.close(uart_id)
end

return xmodem
