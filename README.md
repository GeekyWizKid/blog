# 我的 Hugo 博客

基于 Hugo + PaperMod 主题，包含以下版块：

- 技术（`/tech`）
- 日常（`/life`）
- 读书（`/books`）
- 照片（`/photos`）

## 本地运行

```
hugo server -D
```

在浏览器打开 http://localhost:1313

## 写作

- 文章放在 `content/<section>/` 下，例如：
  - 技术：`content/tech/xxx.md`
  - 日常：`content/life/xxx.md`
  - 读书：`content/books/xxx.md`
  - 照片：`content/photos/xxx.md`（图片放到 `static/photos` 下）

## 生产构建

```
hugo --minify
```

静态文件输出到 `public/`。

## 部署到 Vercel（推荐快速上云）

已内置 `vercel.json` 与脚本 `scripts/vercel-build.sh`，支持预览与生产的自动 `baseURL`：

1) 推送代码到 GitHub/GitLab

2) Vercel → New Project → Import 本仓库，设置：
- Framework Preset：Other
- Build Command：`bash scripts/vercel-build.sh`
- Output Directory：`public`

3) 预览环境自动使用 `https://$VERCEL_URL/` 作为 `baseURL`，链接静态资源均正确

4) 绑定你的生产域名后（Vercel → Domains），在 Project → Settings → Environment Variables 设置：
- `PROD_BASE_URL` = `https://你的域名/`

5) 合并到 `main/master` 即生成生产版本，使用 `PROD_BASE_URL`

注意：Vercel 在中国大陆的可达性因网络而异，作为早期内容托管足够方便；若面向大陆长期访问，后续建议迁移到国内对象存储+CDN 或你的 NAS，并使用备案域名。

## 部署到群晖 NAS（Web Station）

1) 在 DSM 安装并启用 Web Station（套件中心 → Web Station）。首次安装会创建共享文件夹 `web`（通常位于 `/volume1/web`）。

2) Web Station → 虚拟主机 → 新增：
- 端口：80（如公网使用再配 443 与证书）
- 文档根目录：选择/创建如 `/volume1/web/blog`
- 后端：Nginx 即可（纯静态无需 PHP）

3) 构建并拷贝：
```
hugo --minify
rsync -avz --delete public/ <your-user>@<nas-ip>:/volume1/web/blog/
```
提示：也可通过 Finder/资源管理器挂载 `\<nas-ip>\web` 直接复制 `public/*`。

4) 访问地址：
- 局域网：`http://<nas-ip>/` 或 `http://<nas-ip>/blog/`（取决于虚拟主机配置）
- 公网：设置 DDNS（控制面板 → 外部访问）、路由器端口转发 80/443、证书（控制面板 → 安全性 → 证书）。

可选：如不想端口转发，可用 Cloudflare Tunnel/FRP 等内网穿透；若面向中国大陆公网长期访问，建议备案与接入国内 CDN 获得更稳定带宽。

## 一键部署到 NAS（GitHub Actions）

已提供 `.github/workflows/deploy-to-nas.yml`：推送到 `main/master` 自动构建并用 rsync 发布到 NAS。

准备工作：
- DSM 启用 SSH（控制面板 → 终端机和 SNMP → 勾选启用 SSH）
- 为有写权限的用户设置 SSH 公钥登录（`~/.ssh/authorized_keys`）
- 在仓库 Secrets 设置：
  - `NAS_HOST`：公网或内网地址
  - `NAS_USER`：登录用户
  - `NAS_PORT`：默认 `22`
  - `NAS_TARGET_DIR`：如 `/volume1/web/blog`
  - `NAS_SSH_PRIVATE_KEY`：对应公钥的私钥内容

或在本机使用脚本：
```
NAS_HOST=192.168.1.10 NAS_USER=youruser NAS_DIR=/volume1/web/blog \
NAS_PORT=22 ./scripts/deploy-to-nas.sh
```

## 部署（面向中国大陆）

推荐使用阿里云 OSS（或腾讯云 COS）+ CDN：

- 已内置 GitHub Actions 工作流：`.github/workflows/deploy-aliyun-oss.yml`
- 在仓库 Settings → Secrets 中配置：
  - `OSS_ENDPOINT`（例：`oss-cn-hangzhou.aliyuncs.com`）
  - `OSS_BUCKET`（你的 Bucket 名）
  - `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`
- 推送到 `main`/`master` 分支将自动构建并同步到 OSS

若使用自定义域名，请在 OSS/域名服务商处开启静态网站托管并绑定 CDN，解析到 CNAME。

## 其它注意

- 主题：`themes/PaperMod`（无外链字体/脚本，适合大陆访问）
- `hugo.toml` 中 `baseURL` 请改为你的域名
- 字数统计、TOC、代码高亮等可在 `hugo.toml` 里按需开启
