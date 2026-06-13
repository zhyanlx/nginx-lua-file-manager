# OpenResty 文件下载管理页

一个基于 OpenResty/Nginx + Lua 的轻量级文件下载管理页面，适合部署为个人文件下载站、内网工具下载站或临时文件管理页。

## 功能

- 文件/目录列表展示
- 文件类型图标、文件大小统计
- 搜索、排序
- 管理模式密码登录
- 新建目录
- 单条删除
- 批量删除
- 多选移动到指定目录
- 小文件上传
- 大文件分片上传
- 上传进度展示
- 登录失败限流
- 移动目录选择弹框
- 居中样式化提示弹框

## 页面截图

> 以下图片路径为建议命名。上传 GitHub 前，请将实际截图放到 `docs/screenshots/` 目录中。

```text
docs/screenshots/home.png          # 首页/文件列表
docs/screenshots/manage-mode.png   # 管理模式
docs/screenshots/move-dialog.png   # 移动目录弹框
docs/screenshots/upload-dialog.png # 上传弹框
docs/screenshots/alert-modal.png   # 居中提示弹框
```

README 中可以这样引用：

```md
![首页](docs/screenshots/home.png)
![管理模式](docs/screenshots/manage-mode.png)
![移动目录弹框](docs/screenshots/move-dialog.png)
```

如果暂时没有截图，可以先保留本节，后续补图。

## 文件说明

```text
.index.lua   # 目录索引页面、管理操作接口：登录、新建目录、删除、批量删除、移动等
.upload.lua  # 上传接口：普通上传、分片上传、断点检查、合并分片
README.md    # 部署说明
```

## 部署前必须修改的配置

开源版本中的敏感配置均使用占位值，部署前请按实际环境修改。

### 1. 修改下载根目录

文件：`.index.lua`

```lua
local BASE_DIR = "/opt/www/download"
```

文件：`.upload.lua`

```lua
local BASE_DIR = "/opt/www/download"
```

`BASE_DIR` 必须和 Nginx/OpenResty 站点 `root` 指向的目录保持一致。

例如你想部署到：

```text
/data/file-site
```

则两个文件都要改成：

```lua
local BASE_DIR = "/data/file-site"
```

### 2. 修改管理密码

文件：`.index.lua`

```lua
local PASSWORD = "change-me"
```

文件：`.upload.lua`

```lua
local PASSWORD = "change-me"
```

请把两个文件中的 `change-me` 改成你自己的强密码，并且两个文件必须保持一致。

示例：

```lua
local PASSWORD = "your-strong-password"
```

> 注意：不要使用默认密码；如果仓库公开，建议不要提交真实密码。可以在部署服务器上单独修改。

### 3. 修改上传临时目录，可选

文件：`.upload.lua`

```lua
local UPLOAD_TEMP = "/tmp/upload_chunks"
```

这是大文件分片上传的临时目录。默认使用 `/tmp/upload_chunks`，一般可以不改。

如果上传文件较大，建议改到空间更充足的目录，例如：

```lua
local UPLOAD_TEMP = "/data/upload_chunks"
```

并确保 Nginx/OpenResty worker 用户有读写权限。

## 前置依赖

需要安装：

- OpenResty 或支持 `content_by_lua_file` 的 Nginx + Lua 模块
- `lua-cjson`
- Linux 常用命令：`ls`、`stat`、`mv`、`rm`、`mkdir`

OpenResty 通常已经内置 Lua 和常用模块。

## 推荐目录权限

本项目的管理功能需要 Nginx/OpenResty worker 用户对下载目录有写权限，否则这些操作可能失败：

- 新建目录
- 删除文件/目录
- 批量删除
- 移动文件/目录
- 上传文件

先查看 Nginx worker 用户：

```bash
ps -eo user,comm,args | grep -E 'nginx|openresty' | grep -v grep
```

常见用户是：

```text
www-data
```

下面示例以 `www-data` 和 `/opt/www/download` 为例。

### 推荐方式：让 worker 用户拥有下载目录

```bash
sudo chown -R www-data:www-data /opt/www/download
sudo find /opt/www/download -type d -exec chmod 755 {} \;
sudo find /opt/www/download -type f -exec chmod 644 {} \;
```

如果你的站点目录不是 `/opt/www/download`，请替换为你的实际 `BASE_DIR`。

### 临时兼容方式：只放开目录写权限

如果你不想修改文件归属，也可以只给目录开放写权限：

```bash
sudo find /opt/www/download -type d -exec chmod 757 {} \;
```

这种方式更宽松，不如 `chown` 方式安全，仅建议个人服务器或内网环境临时使用。

## OpenResty/Nginx 配置说明

本项目需要通过 OpenResty/Nginx 的 `content_by_lua_file` 指令加载 `.index.lua` 和 `.upload.lua`。

如果你的 OpenResty 配置按 vhost 拆分，通常可以把站点配置放到类似下面的位置：

```bash
/usr/local/openresty/nginx/conf/vhost/file.example.com.conf
```

你的实际服务器上可能类似：

```bash
/usr/local/openresty/nginx/conf/vhost/your-domain.conf
```

请根据自己的 OpenResty 主配置 `nginx.conf` 中的 `include` 路径决定放在哪里，例如：

```nginx
include /usr/local/openresty/nginx/conf/vhost/*.conf;
```

以下是一个最小可用 HTTPS server 配置示例，请根据你的域名、证书路径和站点目录修改。

```nginx
server {
    listen 80;
    server_name file.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name file.example.com;

    root /opt/www/download;
    charset utf-8;
    client_max_body_size 2048m;

    ssl_certificate /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    location /__static__ {
        internal;
        alias /opt/www/download;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location /__upload__ {
        content_by_lua_file /opt/www/download/.upload.lua;
    }

    location / {
        content_by_lua_file /opt/www/download/.index.lua;
    }
}
```

如果你不使用 HTTPS，可以只保留 `listen 80` 的 server，并去掉 SSL 相关配置。

## 部署步骤示例

以下以 `/opt/www/download` 为例。

### 1. 放置文件

```bash
sudo mkdir -p /opt/www/download
sudo cp .index.lua .upload.lua README.md /opt/www/download/
```

### 2. 修改配置

编辑 `.index.lua` 和 `.upload.lua`：

```bash
sudo vim /opt/www/download/.index.lua
sudo vim /opt/www/download/.upload.lua
```

至少修改：

```lua
local BASE_DIR = "/opt/www/download"
local PASSWORD = "change-me"
```

`.upload.lua` 中如有需要再修改：

```lua
local UPLOAD_TEMP = "/tmp/upload_chunks"
```

### 3. 设置目录权限

推荐：

```bash
sudo chown -R www-data:www-data /opt/www/download
sudo find /opt/www/download -type d -exec chmod 755 {} \;
sudo find /opt/www/download -type f -exec chmod 644 {} \;
```

如果你的 Nginx worker 用户不是 `www-data`，请替换成实际用户。

### 4. 配置 Nginx/OpenResty

将上面的 server 配置保存到你的 OpenResty vhost 配置目录中。

示例：

```bash
sudo vim /usr/local/openresty/nginx/conf/vhost/file.example.com.conf
```

如果你的 OpenResty 没有 `vhost` 目录，可以先创建：

```bash
sudo mkdir -p /usr/local/openresty/nginx/conf/vhost
```

然后确认主配置 `/usr/local/openresty/nginx/conf/nginx.conf` 中包含：

```nginx
include /usr/local/openresty/nginx/conf/vhost/*.conf;
```

如果没有，请加到 `http { ... }` 块内。

### 5. 测试并重载

```bash
sudo /usr/local/openresty/nginx/sbin/nginx -t
sudo /usr/local/openresty/nginx/sbin/nginx -s reload
```

如果使用系统服务管理：

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 使用说明

1. 浏览器访问你的站点。
2. 点击右上角“管理模式”。
3. 输入 `.index.lua` / `.upload.lua` 中配置的 `PASSWORD`。
4. 登录后可执行：
   - 新建目录
   - 上传文件
   - 删除文件/目录
   - 批量删除
   - 多选移动

## 常见问题

### 新建、移动、删除失败

大概率是目录权限问题。请确认 Nginx/OpenResty worker 用户对 `BASE_DIR` 及其子目录有写权限。

检查 worker 用户：

```bash
ps -eo user,comm,args | grep -E 'nginx|openresty' | grep -v grep
```

检查目录权限：

```bash
namei -l /opt/www/download
```

修复权限，推荐：

```bash
sudo chown -R www-data:www-data /opt/www/download
sudo find /opt/www/download -type d -exec chmod 755 {} \;
sudo find /opt/www/download -type f -exec chmod 644 {} \;
```

### 上传大文件失败

检查：

1. Nginx 配置中的 `client_max_body_size` 是否足够大。
2. `.upload.lua` 中 `UPLOAD_TEMP` 所在磁盘空间是否充足。
3. Nginx worker 用户是否有 `UPLOAD_TEMP` 的写权限。

创建并授权上传临时目录：

```bash
sudo mkdir -p /tmp/upload_chunks
sudo chown -R www-data:www-data /tmp/upload_chunks
```

### 修改 Lua 后页面没变化

需要重载 OpenResty/Nginx，并强制刷新浏览器缓存。

```bash
sudo /usr/local/openresty/nginx/sbin/nginx -t
sudo /usr/local/openresty/nginx/sbin/nginx -s reload
```

浏览器强刷：

- Windows/Linux：`Ctrl + F5`
- macOS：`Cmd + Shift + R`

## 安全提醒

本项目适合个人服务器、内网、受控环境使用。公开部署时请注意：

- 必须修改默认 `PASSWORD`。
- 不要把真实密码提交到公开仓库。
- 建议使用 HTTPS。
- 建议限制访问来源，例如通过防火墙、Basic Auth、VPN 或 Nginx allow/deny。
- 上传、删除、移动属于高权限操作，请谨慎开放给公网。
- 如需多人使用、审计日志、细粒度权限，建议接入更完整的认证系统。

## License

请根据你的开源计划补充许可证，例如 MIT、Apache-2.0 或 GPL。