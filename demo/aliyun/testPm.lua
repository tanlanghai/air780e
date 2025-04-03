
-- 低功耗演示
sys.taskInit(function()
    sys.waitUntil("aliyun_ready")
    log.info("aliyun.pm", "阿里云已经连接成功, 5秒后请求进入低功耗模式, USB功能会断开")
    sys.wait(5000)
    local bsp = rtos.bsp():upper()
    -- 进入低功耗模式
    log.info("aliyun.pm", "780E模块进入低功耗模式")
    -- gpio.setup(23,nil)
    -- gpio.close(33)
    -- mobile.rtime(2)  -- RRC快速释放减少connect时间能大幅降低功耗，但是会带来可能得离线风险，可选择延迟时间或者不用
    pm.power(pm.USB, false)
    pm.force(pm.LIGHT)
end)
