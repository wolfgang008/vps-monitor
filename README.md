支持 Ubuntu 22.04/24.04 和 Debian 12。

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/wolfgang008/vps-monitor/main/TG-check-notify.sh | sudo bash
```

快捷命令：

```bash
sudo vps-monitor status       # 查看运行状态、流量、预测和待发报告
sudo vps-monitor doctor       # 全面自检并一键安全修复
sudo vps-monitor test         # 发送 Telegram 测试消息
sudo vps-monitor report       # 立即尝试发送两小时报告
sudo vps-monitor weekly       # 立即发送最早一份待发周报
sudo vps-monitor monthly      # 立即发送最早一份待发月报
sudo vps-monitor collect      # 立即采集一次统计数据
sudo vps-monitor rename       # 修改服务器名称
sudo vps-monitor update       # 安全更新或修复当前版本
vps-monitor --version         # 查看版本
sudo vps-monitor uninstall    # 完全卸载
```

安装损坏、命令入口缺失时的一键卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/wolfgang008/vps-monitor/main/TG-check-notify.sh | sudo bash -s -- --uninstall
```
