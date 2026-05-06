# World Monitor WIRE Daily Brief

自动抓取 World Monitor 顶部 `THE WIRE` 使用的时间线要点，并调用 DeepSeek 生成中文公众号文章草稿，同时保留结构化 JSON 方便复核。

默认输出不是网页链接列表，而是 DeepSeek 根据 `THE WIRE` 时间线要点生成的中文稿件。脚本本身只负责采集、筛选、分类和调用 DeepSeek，不再使用本地 `rewriteRules` 做正文润色。

## 重要说明

World Monitor 的 `robots.txt` 对 `/api/` 路径设置了 `Disallow`。当前需求明确要求使用 WIRE 列表信息，因此配置里通过 `allowApiAccess: true` 显式开启访问。用于公开发布前，请确认你的使用方式符合目标网站条款、版权要求和内部合规要求。

## 运行

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1
```

生成文件会写入 `output/`：

- `YYYY-MM-DD_world-monitor-wire.md`：可发布的中文公众号初稿
- `YYYY-MM-DD_world-monitor-wire.json`：WIRE 原始摘要、分类、强度、提及次数等结构化数据

## 常用参数

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1 -Limit 10 -Days 3
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1 -Out output
```

参数说明：

- `-Limit`：最多纳入多少条 WIRE 事件
- `-Days`：只保留最近多少天更新过的事件
- `-Out`：输出目录
- `-Config`：配置文件路径，默认 `config.json`

## DeepSeek 润色

当前正文由 DeepSeek 生成。需要先配置环境变量或 GitHub Secret：

- `DEEPSEEK_API_KEY`

DeepSeek 接入参数在 `config.json` 的 `world-monitor-wire.article.editor` 中：

- `provider`：固定为 `deepseek`
- `baseUrl`：默认 `https://api.deepseek.com`
- `model`：默认 `deepseek-chat`
- `temperature`：文风发散程度
- `maxTokens`：最大输出长度

如果没有配置 `DEEPSEEK_API_KEY`，脚本会停止运行，避免误把未润色的原始材料发出去。

DeepSeek 会同时输出图片提示词：

- 1 张封面图提示词
- 最多 2 张文章插图提示词

当前已关闭自动图片生成。脚本会生成 TXT 和 `image-prompts.json`，邮件会把它们一起发出。你可以把 `image-prompts.json` 里的提示词复制到 ChatGPT 或其他图片工具中手动生成封面图和插图。

## 每日自动运行

Windows 任务计划程序可以每天定时执行：

```powershell
schtasks /Create /SC DAILY /TN "WorldMonitorWireDaily" /TR "powershell -ExecutionPolicy Bypass -File C:\Users\Administrator\Documents\Codex\2026-05-01\name-bbc-world-type-rss-url\scripts\daily-news.ps1" /ST 08:00
```

建议发布前仍做一次人工核对，尤其是战争、伤亡、恐怖主义、制裁和外交表态类内容。

## GitHub Actions 定时生成

仓库已包含 `.github/workflows/daily-world-monitor.yml`。

它会在每天北京时间 20:30 自动运行，也可以在 GitHub 页面手动触发：

1. 把本项目推送到 GitHub 仓库。
2. 打开仓库的 `Actions` 页面。
3. 选择 `Daily World Monitor Copy`。
4. 点击 `Run workflow` 可手动测试。

自动生成后，文件会出现在两个位置：

- Actions 运行记录里的 `world-monitor-copy` artifact
- 仓库中的 `copy-output/` 和 `output/` 目录

说明：本地运行时仍会输出到桌面 `文案输出` 文件夹；GitHub Actions 上没有你的桌面环境，所以使用 `copy-output/` 作为仓库内的 TXT 输出目录。

GitHub Actions 使用 UTC 时间，配置里的 `30 12 * * *` 对应北京时间晚上 20:30。

## 邮件发送

Workflow 会在生成 TXT 后尝试把当天文案作为附件发送到邮箱。需要在 GitHub 仓库中配置这些 Secrets：

- `SMTP_SERVER`
- `SMTP_PORT`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `EMAIL_FROM`
- `EMAIL_TO`

如果这些 Secrets 没配置，邮件步骤会自动跳过，不影响文件生成。

DeepSeek 还需要额外配置：

- `DEEPSEEK_API_KEY`
