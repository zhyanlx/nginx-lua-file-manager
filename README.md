# File Download Center

基于 OpenResty/Nginx + Lua 的轻量级文件下载管理页面，适合个人文件下载站、内网工具站或临时文件管理。

## 功能

- 文件/目录列表
- 搜索、排序
- 管理密码登录
- 新建目录
- 单条删除、批量删除
- 多选移动
- 文件上传
- 大文件分片上传
- 居中提示弹框

## 页面预览
<img width="2548" height="967" alt="image" src="https://github.com/user-attachments/assets/38dc9ccc-8ca3-4310-b89a-fe06fc34b8d1" />
<img width="2509" height="987" alt="image" src="https://github.com/user-attachments/assets/c7905db1-7cc0-411a-85fb-8571b1a02065" />
<img width="2516" height="857" alt="image" src="https://github.com/user-attachments/assets/2a52e684-8914-4ce6-913f-9256bc7f2401" />


## 文件说明

```text
.index.lua   # 页面展示和管理接口
.upload.lua  # 文件上传接口
README.md    # 使用说明
```

## 部署前需要修改

### 1. 修改站点目录

`.index.lua` 和 `.upload.lua` 中都有：

```lua
local BASE_DIR = "/opt/www/download"
```

把它改成你的实际文件目录

Nginx/OpenResty 配置里的 `root` 也要和这个目录一致。

### 2. 修改管理密码

`.index.lua` 和 `.upload.lua` 中都有：

```lua
local PASSWORD = "change-me"
```

change-me改成你自己的密码，并确保两个文件保持一致。

> 不要把真实密码提交到公开仓库。

### 3. 上传临时目录，可选

`.upload.lua` 中：

```lua
local UPLOAD_TEMP = "/tmp/upload_chunks"
```

默认可以不改。如果上传大文件较多，可以改到空间更大的目录。

## OpenResty 配置示例

示例路径：

```bash
/usr/local/openresty/nginx/conf/vhost/file.example.com.conf
```

示例配置：

```nginx
server {
    listen 80;
    server_name file.example.com;

    root /opt/www/download;
    charset utf-8;
    client_max_body_size 2048m;

    location /__static__ {
        internal;
        alias /opt/www/download;
    }

    location /__upload__ {
        content_by_lua_file /opt/www/download/.upload.lua;
    }

    location / {
        content_by_lua_file /opt/www/download/.index.lua;
    }
}
```

## 部署步骤

以下以 `/opt/www/download` 为例。

### 1. 放置文件

```bash
sudo mkdir -p /opt/www/download
sudo cp .index.lua .upload.lua README.md /opt/www/download/
```

### 2. 修改配置

```bash
sudo vim /opt/www/download/.index.lua
sudo vim /opt/www/download/.upload.lua
```

至少修改：

```lua
local BASE_DIR = "/opt/www/download"
local PASSWORD = "change-me"
```

### 3. 设置目录权限

先查看 OpenResty/Nginx worker 用户：

```bash
ps -eo user,comm,args | grep -E 'nginx|openresty' | grep -v grep
```

假设用户是 `www-data`，推荐这样设置：

```bash
sudo chown -R www-data:www-data /opt/www/download
sudo find /opt/www/download -type d -exec chmod 755 {} \;
sudo find /opt/www/download -type f -exec chmod 644 {} \;
```

### 4. 测试并重载 OpenResty

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 使用方法

1. 浏览器访问站点。
2. 点击右上角“管理模式”。
3. 输入 `PASSWORD` 中配置的密码。
4. 登录后可以上传、新建目录、删除、批量删除、移动文件。

