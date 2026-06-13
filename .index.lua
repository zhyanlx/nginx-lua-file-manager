local BASE_DIR = "/opt/www/download"
local PASSWORD = "change-me"

-- 安全的路径清理函数
local function sanitize_path(s)
    s = tostring(s or "/")
    s = s:gsub("%z", ""):gsub("\\", "/"):gsub("%c", "")
    while s:find("..", 1, true) do
        s = s:gsub("%.%.", "")
    end
    s = s:gsub("/+", "/")
    if s == "" then s = "/" end
    if s:sub(1,1) ~= "/" then s = "/" .. s end
    return s
end

-- Shell 参数转义
local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 格式化文件大小
local function format_size(bytes)
    if not bytes or bytes == "" then return "" end
    bytes = tonumber(bytes)
    if not bytes then return "" end
    if bytes < 1024 then return bytes .. " B"
    elseif bytes < 1048576 then return string.format("%.1f KB", bytes/1024)
    elseif bytes < 1073741824 then return string.format("%.1f MB", bytes/1048576)
    else return string.format("%.2f GB", bytes/1073741824) end
end

-- 获取文件图标
local function get_file_icon(name, is_dir)
    if is_dir then return "📁" end
    local ext = name:match("%.([^%.]+)$")
    ext = ext and ext:lower() or ""
    local icons = {
        mp4="🎬", mkv="🎬", avi="🎬", mov="🎬", flv="🎬", wmv="🎬",
        mp3="🎵", wav="🎵", flac="🎵", aac="🎵", ogg="🎵",
        jpg="🖼️", jpeg="🖼️", png="🖼️", gif="🖼️", bmp="🖼️", webp="🖼️", svg="🖼️",
        zip="📦", rar="📦", ["7z"]="📦", tar="📦", gz="📦",
        pdf="📕", doc="📘", docx="📘", txt="📝", md="📝",
        xls="📊", xlsx="📊", csv="📊",
        exe="⚙️", msi="⚙️", dmg="⚙️",
        js="📜", html="📜", css="📜", lua="📜", py="📜",
    }
    return icons[ext] or "📄"
end

local uri = ngx.var.request_uri
local path = uri:match("^([^%?]*)")
if path == "/favicon.ico" then return ngx.exit(404) end
if path:sub(-1) ~= "/" then path = path .. "/" end
path = sanitize_path(path)
local fp = BASE_DIR .. path

-- ============ Rate Limiting ============
local RATE_FILE = "/tmp/mgmt_rate_limit.json"
local MAX_FAILURES = 5
local LOCKOUT_SECONDS = 600

local function load_rate_data()
    local f = io.open(RATE_FILE, "r")
    if not f then return {} end
    local content = f:read("*a") or "{}"
    f:close()
    local cjson = require("cjson")
    local ok, data = pcall(cjson.decode, content)
    return ok and data or {}
end

local function save_rate_data(data)
    local cjson = require("cjson")
    local content = cjson.encode(data)
    local f = io.open(RATE_FILE, "w")
    if f then f:write(content) f:close() end
end

local function check_rate_limit(ip)
    local data = load_rate_data()
    local entry = data[ip]
    if not entry then return false, 0 end
    local now = ngx.time()
    if now - entry.last_attempt > LOCKOUT_SECONDS then
        data[ip] = nil
        save_rate_data(data)
        return false, 0
    end
    return entry.failures >= MAX_FAILURES, MAX_FAILURES - entry.failures
end

local function record_failure(ip)
    local data = load_rate_data()
    local now = ngx.time()
    local entry = data[ip] or {failures = 0, last_attempt = now}
    entry.failures = entry.failures + 1
    entry.last_attempt = now
    data[ip] = entry
    save_rate_data(data)
    return entry.failures
end

local function clear_rate(ip)
    local data = load_rate_data()
    data[ip] = nil
    save_rate_data(data)
end
-- ============ End Rate Limiting ============

-- ============ Management Handler ============
local ct = ngx.req.get_headers()["content-type"] or ""
if ct:find("application/json", 1, true) then
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        local cjson = require("cjson")
        local ok, data = pcall(cjson.decode, body)
        if ok and data and data.action then
            local client_ip = ngx.var.remote_addr
            if data.action == "auth" then
                local locked = check_rate_limit(client_ip)
                if locked then
                    ngx.say('{"success":false,"message":"登录失败次数过多，请10分钟后重试"}')
                    return
                end
                if data.password == PASSWORD then
                    clear_rate(client_ip)
                    ngx.say('{"success":true}')
                else
                    local count = record_failure(client_ip)
                    local left = MAX_FAILURES - count
                    if left > 0 then
                        ngx.say('{"success":false,"message":"密码错误，还可尝试' .. left .. '次"}')
                    else
                        ngx.say('{"success":false,"message":"登录失败次数过多，请10分钟后重试"}')
                    end
                end
                return
            elseif data.action == "create_dir" then
                if data.password ~= PASSWORD then ngx.say('{"success":false,"message":"未授权"}') return end
                local name = data.name
                if not name or name == "" then ngx.say('{"success":false,"message":"目录名称不能为空"}') return end
                name = name:gsub("[/\\]", "")
                if name == "" then ngx.say('{"success":false,"message":"目录名称不能为空"}') return end
                local full_path = fp .. name
                local exists = os.execute("test -e " .. shell_quote(full_path) .. " 2>/dev/null")
                if exists == true or exists == 0 then
                    ngx.say('{"success":false,"message":"同名文件或目录已存在"}')
                    return
                end
                local ret = os.execute("mkdir -- " .. shell_quote(full_path) .. " 2>/dev/null")
                if ret == true or ret == 0 then
                    ngx.say('{"success":true}')
                else
                    ngx.say('{"success":false,"message":"创建目录失败"}')
                end
                return
            elseif data.action == "delete" then
                if data.password ~= PASSWORD then ngx.say('{"success":false,"message":"未授权"}') return end
                local name = data.name
                if not name or name == "" then ngx.say('{"success":false,"message":"请选择要删除的项目"}') return end
                name = name:gsub("[/\\]", "")
                local full_path = fp .. name
                if data.type == "dir" then
                    os.execute("rm -rf -- " .. shell_quote(full_path) .. " 2>/dev/null")
                else
                    os.execute("rm -f -- " .. shell_quote(full_path) .. " 2>/dev/null")
                end
                ngx.say('{"success":true}')
                return
            elseif data.action == "batch_delete" then
                if data.password ~= PASSWORD then ngx.say('{"success":false,"message":"未授权"}') return end
                local items = data.items
                if not items or #items == 0 then ngx.say('{"success":false,"message":"请选择要删除的项目"}') return end
                local errors = {}
                for _, item in ipairs(items) do
                    local name = item.name
                    if name and name ~= "" then
                        name = name:gsub("[/\\]", "")
                        local full_path = fp .. name
                        local cmd
                        if item.type == "dir" then
                            cmd = "rm -rf -- " .. shell_quote(full_path) .. " 2>/dev/null"
                        else
                            cmd = "rm -f -- " .. shell_quote(full_path) .. " 2>/dev/null"
                        end
                        local ret = os.execute(cmd)
                        local ok = ret == true or ret == 0
                        if not ok then
                            errors[#errors + 1] = name
                        end
                    end
                end
                if #errors > 0 then
                    local cjson = require("cjson")
                    ngx.say(cjson.encode({success=false,message="部分项目删除失败: " .. table.concat(errors, ", ")}))
                else
                    ngx.say('{"success":true}')
                end
                return
            elseif data.action == "move" then
                if data.password ~= PASSWORD then ngx.say('{"success":false,"message":"未授权"}') return end
                local items = data.items
                local target = data.target
                if not items or #items == 0 then ngx.say('{"success":false,"message":"请选择要移动的项目"}') return end
                if not target then ngx.say('{"success":false,"message":"请选择目标目录"}') return end
                target = target:gsub("%z", ""):gsub("\\", "/"):gsub("%c", ""):gsub("%.%.", ""):gsub("/+", "/")
                if target ~= "/" and target:sub(-1) ~= "/" then target = target .. "/" end
                local target_path = BASE_DIR .. target
                -- 检查目标目录是否存在
                local tf = io.open(target_path, "r")
                if not tf then ngx.say('{"success":false,"message":"目标目录不存在"}') return end
                tf:close()
                local errors = {}
                for _, name in ipairs(items) do
                    name = name:gsub("[/\\]", "")
                    local src = fp .. name
                    local dst = target_path .. name
                    local ok = os.rename(src, dst)
                    if not ok then
                        local cmd = "mv -- " .. shell_quote(src) .. " " .. shell_quote(dst) .. " 2>/dev/null"
                        local ret = os.execute(cmd)
                        ok = ret == true or ret == 0
                    end
                    if not ok then
                        errors[#errors + 1] = name
                    end
                end
                if #errors > 0 then
                    local cjson = require("cjson")
                    ngx.say(cjson.encode({success=false,message="部分文件移动失败: " .. table.concat(errors, ", ")}))
                else
                    ngx.say('{"success":true}')
                end
                return
            end
        end
    end
    ngx.say('{"success":false,"message":"未知操作"}')
    return
end

-- 列出当前目录下的子目录（用于移动功能）
if ngx.var.request_uri:find("__action=list_dirs") then
    ngx.header.content_type = "application/json; charset=utf-8"
    local target_path = ngx.var.arg_path or "/"
    target_path = ngx.unescape_uri(target_path)
    target_path = target_path:gsub("%z", ""):gsub("\\", "/"):gsub("%c", ""):gsub("%.%.", ""):gsub("/+", "/")
    if target_path:sub(-1) ~= "/" then target_path = target_path .. "/" end
    local full_path = BASE_DIR .. target_path
    local dirs = {}
    local p = io.popen('ls -1a "' .. full_path .. '" 2>/dev/null')
    if p then
        local skip = {["."]=1, [".."]=1, [".htaccess"]=1, [".user.ini"]=1, [".index.lua"]=1, ["__pycache__"]=1}
        for line in p:lines() do
            if not skip[line] and line:sub(1,1) ~= "." then
                local test = io.open(full_path .. line .. "/", "r")
                if test then
                    test:close()
                    dirs[#dirs + 1] = target_path .. line .. "/"
                end
            end
        end
        p:close()
    end
    local cjson = require("cjson")
    ngx.say(cjson.encode(dirs))
    return
end
-- ============ End Management Handler ============

local f = io.open(fp, "r")
if not f then
    ngx.status = 404
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say("<h1>404 Not Found</h1>")
    return
end
f:close()
local testdir = io.open(fp .. "/", "r")
if testdir then testdir:close() else
    ngx.req.set_uri("/__static__")
    ngx.exec("@static")
    return
end

-- ============ Scan Directory First ============
local p = io.popen('ls -1a "' .. fp .. '" 2>/dev/null')
local entries = {}
local dir_count = 0
local file_count = 0
local total_size = 0
if p then
    local skip = {["."]=1, [".."]=1, [".htaccess"]=1, [".user.ini"]=1, [".index.lua"]=1, ["__pycache__"]=1}
    for line in p:lines() do
        if not skip[line] and line:sub(1,1) ~= "." then
            local tp = fp .. line
            local isd = false
            local sz = ""
            -- 使用单个 stat 命令获取类型和大小
            local sp = io.popen('stat -c "%F %s" "' .. tp .. '" 2>/dev/null')
            if sp then
                local info = sp:read("*l") or ""
                sp:close()
                local fsize = info:match("(%d+)%s*$")
                local ftype = info:match("^(.-%S+)%s+%d+%s*$")
                if ftype and ftype:find("directory") then
                    isd = true
                else
                    sz = fsize or ""
                    if sz ~= "" then total_size = total_size + tonumber(sz) end
                end
            end
            if isd then dir_count = dir_count + 1 else file_count = file_count + 1 end
            entries[#entries + 1] = {name = line, is_dir = isd, size = sz}
        end
    end
    p:close()
end

-- ============ Generate Breadcrumb ============
local breadcrumb = '<a href="/">首页</a>'
local parts = {}
for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
local current_path = ""
for i, part in ipairs(parts) do
    current_path = current_path .. "/" .. part
    if i < #parts then
        breadcrumb = breadcrumb .. ' <span class="bc-sep">/</span> <a href="' .. current_path .. '/">' .. part .. '</a>'
    else
        breadcrumb = breadcrumb .. ' <span class="bc-sep">/</span> <span class="bc-current">' .. part .. '</span>'
    end
end

-- ============ Generate HTML ============
local total_size_str = format_size(total_size)
local html = [[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>]]..path..[[ - 下载</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;color:#333;min-height:100vh}
.hdr{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:24px 28px;border-radius:0 0 16px 16px;box-shadow:0 4px 24px rgba(102,126,234,.2);text-align:center;position:relative}
.hdr h1{font-size:22px;font-weight:700;margin:0 0 10px;letter-spacing:-.5px}
.hdr-stats{display:flex;justify-content:center;gap:16px;font-size:13px;opacity:.9;margin-bottom:10px}
.hdr-stats span{display:inline-flex;align-items:center;gap:6px;background:rgba(255,255,255,.15);padding:5px 12px;border-radius:20px}
.hdr-path{display:flex;align-items:center;justify-content:center;gap:12px;font-size:14px}
.hdr-path .path{color:rgba(255,255,255,.85)}
.hdr-path .back-btn{color:rgba(255,255,255,.9);text-decoration:none;font-size:13px;padding:6px 14px;border-radius:8px;background:rgba(255,255,255,.18);transition:all .2s;border:1px solid rgba(255,255,255,.2);font-weight:500}
.hdr-path .back-btn:hover{background:rgba(255,255,255,.28)}
.list{max-width:1000px;margin:20px auto;padding:0 20px}
.card{background:#fff;border-radius:16px;box-shadow:0 1px 3px rgba(0,0,0,.04),0 4px 16px rgba(0,0,0,.04);overflow:hidden;border:1px solid #e5e7eb}
.sort-bar{display:flex;padding:12px 20px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#9ca3af;gap:16px;background:#fafbfc;align-items:center;justify-content:space-between}
.sort-left{display:flex;gap:16px}
.sort-bar span{cursor:pointer;transition:all .2s;padding:4px 10px;border-radius:6px}
.sort-bar span:hover,.sort-bar span.active{color:#667eea;background:#eef2ff}
.mkdir-btn,.upload-btn{padding:6px 14px;border:1px solid #e5e7eb;border-radius:8px;background:#fff;color:#374151;font-size:12px;cursor:pointer;transition:all .2s;font-weight:500}
.mkdir-btn:hover,.upload-btn:hover{background:#f9fafb;border-color:#d1d5db}
.action-btns{display:flex;gap:8px}
.batch-btn{padding:6px 14px;border:1px solid #c7d2fe;border-radius:8px;background:#eef2ff;color:#667eea;font-size:12px;cursor:pointer;transition:all .2s;font-weight:500}
.batch-btn:hover{background:#dde5ff}
.row-check-wrap{display:flex;align-items:center;padding:0 8px 0 12px;cursor:pointer}
.row-check{width:16px;height:16px;cursor:pointer;accent-color:#667eea}
.dir-tree{max-height:300px;overflow-y:auto;border:1px solid #e5e7eb;border-radius:10px;margin:12px 0;padding:8px;background:#f9fafb}
.dir-item{padding:8px 12px;cursor:pointer;border-radius:6px;font-size:14px;display:flex;align-items:center;gap:8px;transition:all .15s}
.dir-item:hover{background:#eef2ff}
.dir-item.selected{background:#eef2ff!important;color:#374151;box-shadow:inset 3px 0 0 #667eea;font-weight:500}
.dir-item .dir-icon{font-size:16px}
.upload-select{border:2px dashed #e5e7eb;border-radius:12px;padding:30px 20px;text-align:center;cursor:pointer;transition:all .2s;margin:16px 0}
.upload-select:hover{border-color:#667eea;background:#f8f9ff}
.upload-icon{font-size:36px;margin-bottom:8px}
.upload-select p{color:#6b7280;font-size:14px;margin:0}
.upload-progress{display:none;margin:12px 0}
.progress-bar{height:6px;background:#e5e7eb;border-radius:3px;overflow:hidden}
.progress-fill{height:100%;background:linear-gradient(90deg,#667eea,#764ba2);width:0;transition:width .3s}
.upload-status{font-size:12px;color:#6b7280;margin-top:6px}
.toast{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:rgba(0,0,0,.75);color:#fff;padding:12px 28px;border-radius:10px;font-size:14px;z-index:2000;animation:toastIn .3s ease}
@keyframes toastIn{from{opacity:0;transform:translate(-50%,-50%) scale(.9)}to{opacity:1;transform:translate(-50%,-50%) scale(1)}}
.row{display:flex;align-items:center;padding:14px 20px;border-bottom:1px solid #f3f4f6;transition:all .15s;text-decoration:none;color:inherit;position:relative}
.row:hover{background:#f9fafb}
.row:last-child{border-bottom:none}
.ico{width:42px;height:42px;border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0;margin-right:14px}
.dir{background:#ecfdf5}.file{background:#eff6ff}
.nfo{flex:1;min-width:0}
.nm{font-size:14px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#1f2937}
.sz{font-size:12px;color:#9ca3af;margin-top:3px}
.arr{color:#d1d5db;font-size:18px;margin-left:8px}
.empty{text-align:center;padding:60px 20px;color:#9ca3af}
.empty .icon{font-size:48px;margin-bottom:12px}
.modal-bg{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.4);backdrop-filter:blur(4px);z-index:1000;justify-content:center;align-items:center}
.modal-bg.show{display:flex}
.modal{background:#fff;border-radius:20px;padding:28px;width:380px;max-width:90vw;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.15);animation:modalIn .2s ease}
@keyframes modalIn{from{opacity:0;transform:scale(.95) translateY(10px)}to{opacity:1;transform:scale(1) translateY(0)}}
.modal h3{margin-bottom:20px;font-size:18px;font-weight:600;color:#1f2937}
.modal input{width:100%;padding:12px 16px;border:2px solid #e5e7eb;border-radius:12px;font-size:14px;outline:none;transition:border-color .2s;background:#f9fafb}
.modal input:focus{border-color:#667eea;background:#fff}
.modal .btns{display:flex;gap:10px;margin-top:20px}
.modal .btns button{flex:1;padding:11px;border:none;border-radius:12px;font-size:14px;cursor:pointer;font-weight:500;transition:all .2s}
.btn-cancel{background:#f3f4f6;color:#6b7280}
.btn-cancel:hover{background:#e5e7eb}
.btn-ok{background:linear-gradient(135deg,#667eea,#764ba2);color:#fff}
.btn-ok:hover{opacity:.9;transform:translateY(-1px)}
.fab{position:absolute;top:16px;right:16px;padding:8px 16px;border-radius:8px;background:rgba(255,255,255,.2);color:#fff;border:1px solid rgba(255,255,255,.3);font-size:13px;cursor:pointer;transition:all .2s;backdrop-filter:blur(4px);font-weight:500}
.fab:hover{background:rgba(255,255,255,.35)}
.row-wrap{display:flex;align-items:center}
.row-check-wrap{display:none;align-items:center;padding:0 8px 0 12px;cursor:pointer}
.row-wrap .row{flex:1;border-radius:0}
.del-btn{display:none;color:#ef4444;background:none;border:none;font-size:13px;cursor:pointer;padding:6px 14px;border-radius:8px;flex-shrink:0;align-self:center;transition:all .2s}
.del-btn:hover{background:#fef2f2;color:#dc2626}
.search-box{padding:12px 20px;border-bottom:1px solid #f0f0f0;background:#fafbfc}
.search-box input{width:100%;padding:10px 14px;border:1px solid #e5e7eb;border-radius:10px;font-size:14px;outline:none;transition:all .2s;background:#fff}
.search-box input:focus{border-color:#667eea;box-shadow:0 0 0 3px rgba(102,126,234,.1)}

@media(max-width:640px){
  .hdr{padding:18px 16px}
  .hdr h1{font-size:18px}
  .hdr-stats{gap:10px;flex-wrap:wrap}
  .hdr-stats span{font-size:12px;padding:4px 10px}
  .hdr-path{font-size:13px;flex-wrap:wrap}
  .hdr-path .back-btn{font-size:12px;padding:5px 12px}
  .list{padding:0 12px}
  .sort-bar{padding:10px 12px;gap:10px;font-size:11px}
}
</style>
</head>
<body>
<div class="hdr">
  <h1>📂 下载中心</h1>
  <div class="hdr-stats">
    <span>📁 ]]..dir_count..[[ 个目录</span>
    <span>📄 ]]..file_count..[[ 个文件</span>
    ]]..(total_size_str ~= "" and '<span>💾 '..total_size_str..'</span>' or '')..[[
  </div>
  <div class="hdr-path">
    <span class="path">]]..(path == "/" and "/" or path)..[[</span>
]]
if path ~= "/" then
    html = html .. '    <a class="back-btn" href="../">⬆️ 返回上级</a>\n'
end
html = html .. [[  </div>
  <button class="fab" id="fabBtn" onclick="showPw()">管理模式</button>
</div>

<div class="list">
<div class="card">
]]
-- ============ Entries ============
-- 搜索框和操作按钮（始终显示）
html = html .. '<div class="search-box"><input type="text" id="searchInput" placeholder="🔍 搜索文件..." oninput="filterList()"></div>'
html = html .. '<div class="sort-bar"><div class="sort-left"><span class="active" data-sort="default" onclick="sortList(\'default\')">默认排序</span><span data-sort="name" onclick="sortList(\'name\')">按名称</span><span data-sort="size" onclick="sortList(\'size\')">按大小</span></div><div class="action-btns"><button class="batch-btn" id="moveBtn" style="display:none" onclick="showMove()">📦 移动到</button><button class="batch-btn" id="batchDelBtn" style="display:none;color:#ef4444;border-color:#fecaca;background:#fef2f2" onclick="showBatchDelete()">🗑️ 批量删除</button><button class="mkdir-btn" id="mkdirBtn" style="display:none" onclick="createDir()">📁 新建目录</button><button class="upload-btn" id="uploadBtn" style="display:none" onclick="showUpload()">📤 上传文件</button></div></div>'
if #entries == 0 then
    html = html .. '<div class="empty"><div class="icon">📂</div>这里还没有任何东西</div>'
else
    -- 排序：目录在前，然后按名称
    table.sort(entries, function(a,b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name < b.name
    end)
    for _, e in ipairs(entries) do
        local cls = e.is_dir and "dir" or "file"
        local ic = get_file_icon(e.name, e.is_dir)
        local sz = format_size(e.size)
        local inf = e.is_dir and '<div class="sz">'..sz..'</div>' or '<div class="sz">'..(sz == "" and "未知大小" or sz)..'</div>'
        local arr = e.is_dir and '<span class="arr">›</span>' or ''
        local row_del = '<button class="del-btn" onclick="event.stopPropagation();event.preventDefault();delItem(\''..e.name..'\',\''..(e.is_dir and 'dir' or 'file')..'\')">删除</button>'
        local size_attr = e.size ~= "" and ' data-size="'..e.size..'"' or ' data-size="0"'
        local checkbox = '<input type="checkbox" class="row-check" data-name="'..e.name..'" data-type="'..(e.is_dir and 'dir' or 'file')..'" onclick="event.stopPropagation();updateSelection()">'
        html = html..'<div class="row-wrap" data-name="'..e.name:lower()..'"'..size_attr..'><label class="row-check-wrap">'..checkbox..'</label><a class="row" href="'..e.name..(e.is_dir and '/' or '')..'"><div class="ico '..cls..'">'..ic..'</div><div class="nfo"><div class="nm">'..e.name..'</div>'..inf..'</div>'..arr..'</a>'..row_del..'</div>'
    end
end
html = html..[[</div></div>
<div class="modal-bg" id="pwModal">
<div class="modal">
<h3>请输入管理密码</h3>
<input type="password" id="pwInput" placeholder="密码" onkeydown="if(event.key==='Enter')authMgmt()">
<div class="btns">
<button class="btn-cancel" onclick="closePw()">取消</button>
<button class="btn-ok" onclick="authMgmt()">确认</button>
</div>
</div>
</div>
<div class="modal-bg" id="delModal">
<div class="modal">
<h3>确定删除？</h3>
<p id="delName" style="margin:12px 0;color:#666;word-break:break-all"></p>
<div class="btns">
<button class="btn-ok" style="background:linear-gradient(135deg,#ef4444,#dc2626)" onclick="doDelete()">确认删除</button>
<button class="btn-cancel" onclick="closeDel()">取消</button>
</div>
</div>
</div>
<div class="modal-bg" id="alertModal">
<div class="modal">
<h3 id="alertTitle">提示</h3>
<p id="alertMsg" style="margin:12px 0;color:#666;word-break:break-all;line-height:1.6"></p>
<div class="btns">
<button class="btn-ok" onclick="closeAlert()">确定</button>
</div>
</div>
</div>
<div class="modal-bg" id="mkdirModal">
<div class="modal">
<h3>新建目录</h3>
<input type="text" id="mkdirInput" placeholder="请输入目录名称" onkeydown="if(event.key==='Enter')doCreateDir()">
<div class="btns">
<button class="btn-ok" onclick="doCreateDir()">创建</button>
<button class="btn-cancel" onclick="closeMkdir()">取消</button>
</div>
</div>
</div>
<div class="modal-bg" id="moveModal">
<div class="modal">
<h3>移动到</h3>
<p id="moveSelected" style="margin:12px 0;color:#6b7280;font-size:13px"></p>
<div class="dir-tree" id="dirTree"></div>
<div class="btns">
<button class="btn-ok" onclick="doMove()">移动到此</button>
<button class="btn-cancel" onclick="closeMove()">取消</button>
</div>
</div>
</div>
<div class="modal-bg" id="uploadModal">
<div class="modal">
<h3>上传文件</h3>
<div class="upload-select" onclick="document.getElementById('fileInput').click()">
  <div class="upload-icon">📁</div>
  <p id="uploadFileName">点击选择文件</p>
</div>
<input type="file" id="fileInput" style="display:none" onchange="onFileSelect(this)">
<div class="upload-progress" id="uploadProgress">
  <div class="progress-bar"><div class="progress-fill" id="progressFill"></div></div>
  <div class="upload-status" id="uploadStatus">准备上传...</div>
</div>
<div class="btns">
<button class="btn-ok" id="uploadSubmitBtn" onclick="doUpload()">上传</button>
<button class="btn-cancel" onclick="closeUpload()">取消</button>
</div>
</div>
</div>
<script>
var mgmtOn=false,mgmtPwd='',selectedItems=[];
function enterMgmt(){document.getElementById('fabBtn').textContent='退出管理';document.getElementById('fabBtn').onclick=exitMgmt;document.getElementById('mkdirBtn').style.display='block';document.getElementById('uploadBtn').style.display='block';document.querySelectorAll('.del-btn').forEach(function(b){b.style.display='flex'});document.querySelectorAll('.row-check-wrap').forEach(function(b){b.style.display='flex'})}
function leaveMgmt(){document.getElementById('fabBtn').textContent='管理模式';document.getElementById('fabBtn').onclick=showPw;document.getElementById('mkdirBtn').style.display='none';document.getElementById('uploadBtn').style.display='none';document.getElementById('moveBtn').style.display='none';document.getElementById('batchDelBtn').style.display='none';document.querySelectorAll('.del-btn').forEach(function(b){b.style.display='none'});document.querySelectorAll('.row-check-wrap').forEach(function(b){b.style.display='none'});document.querySelectorAll('.row-check').forEach(function(c){c.checked=false});selectedItems=[]}
function updateSelection(){selectedItems=[];document.querySelectorAll('.row-check:checked').forEach(function(c){selectedItems.push({name:c.dataset.name,type:c.dataset.type})});var show=selectedItems.length>0?'block':'none';document.getElementById('moveBtn').style.display=show;document.getElementById('batchDelBtn').style.display=show}
(function(){var s=sessionStorage.getItem('mgmtPwd');if(s){mgmtOn=true;mgmtPwd=s;enterMgmt()}})();
function showPw(){document.getElementById('pwModal').classList.add('show');document.getElementById('pwInput').focus()}
function closePw(){document.getElementById('pwModal').classList.remove('show');document.getElementById('pwInput').value=''}
function authMgmt(){var p=document.getElementById('pwInput').value;if(!p)return;api({action:'auth',password:p},function(r){if(r.success){mgmtOn=true;mgmtPwd=p;sessionStorage.setItem('mgmtPwd',p);enterMgmt();closePw()}else{showAlert(r.message||'密码错误')}})}
function exitMgmt(){mgmtOn=false;mgmtPwd='';sessionStorage.removeItem('mgmtPwd');leaveMgmt()}
function showAlert(msg,title){document.getElementById('alertTitle').textContent=title||'提示';document.getElementById('alertMsg').textContent=msg||'';document.getElementById('alertModal').classList.add('show')}
function closeAlert(){document.getElementById('alertModal').classList.remove('show')}
function api(d,cb){var x=new XMLHttpRequest();x.open('POST',location.href,true);x.setRequestHeader('Content-Type','application/json');x.onload=function(){try{cb(JSON.parse(x.responseText))}catch(e){showAlert('请求失败')}};x.onerror=function(){showAlert('网络错误')};x.send(JSON.stringify(d))}
function createDir(){if(!mgmtOn)return;document.getElementById('mkdirModal').classList.add('show');document.getElementById('mkdirInput').focus()}
function closeMkdir(){document.getElementById('mkdirModal').classList.remove('show');document.getElementById('mkdirInput').value=''}
function doCreateDir(){var n=document.getElementById('mkdirInput').value;if(!n||n.trim()=='')return;closeMkdir();api({action:'create_dir',name:n.trim(),password:mgmtPwd},function(r){if(r.success){showToast('创建成功');setTimeout(function(){location.reload()},800)}else{showAlert(r.message||'创建失败')}})}
var delTarget={mode:'single',name:'',type:'',items:[]};
function delItem(n,t,e){e&&e.stopPropagation();e&&e.preventDefault();if(!mgmtOn)return;delTarget={mode:'single',name:n,type:t,items:[]};document.getElementById('delName').textContent=n;document.getElementById('delModal').classList.add('show')}
function showBatchDelete(){if(!mgmtOn)return;if(selectedItems.length===0){showAlert('请先选择要删除的项目');return}delTarget={mode:'batch',name:'',type:'',items:selectedItems.slice()};var names=selectedItems.slice(0,5).map(function(i){return i.name}).join('、');if(selectedItems.length>5)names+=' 等';document.getElementById('delName').textContent='将删除 '+selectedItems.length+' 项：'+names;document.getElementById('delModal').classList.add('show')}
function closeDel(){document.getElementById('delModal').classList.remove('show');delTarget={mode:'single',name:'',type:'',items:[]}}
function doDelete(){var target=delTarget;closeDel();if(target.mode==='batch'){api({action:'batch_delete',items:target.items,password:mgmtPwd},function(r){if(r.success){showToast('删除成功');setTimeout(function(){location.reload()},800)}else{showAlert(r.message||'删除失败')}});return}api({action:'delete',name:target.name,type:target.type,password:mgmtPwd},function(r){if(r.success){showToast('删除成功');setTimeout(function(){location.reload()},800)}else{showAlert(r.message||'删除失败')}})}
var CHUNK_SIZE=5*1024*1024;var uploading=false;var uploadAbort=null;
function showToast(msg){var t=document.createElement('div');t.className='toast';t.textContent=msg;document.body.appendChild(t);setTimeout(function(){t.remove()},1500)}
var moveTarget='',currentDir=']]..path..[[';
function showMove(){if(selectedItems.length===0){showAlert('请先选择文件或目录');return}
document.getElementById('moveSelected').textContent=moveTarget?'目标：'+moveTarget:'已选择 '+selectedItems.length+' 项';document.getElementById('moveModal').classList.add('show');loadDirTree()}
function closeMove(){document.getElementById('moveModal').classList.remove('show');moveTarget=''}
function paintMoveSelection(){document.querySelectorAll('#dirTree .dir-item').forEach(function(i){var on=i.getAttribute('data-path')===moveTarget;i.classList.toggle('selected',on);if(on){i.style.background='#eef2ff';i.style.boxShadow='inset 3px 0 0 #667eea';i.style.fontWeight='500'}else{i.style.background='';i.style.boxShadow='';i.style.fontWeight=''}})}
function makeDirItem(path,label,icon){var item=document.createElement('div');item.className='dir-item';item.setAttribute('data-path',path);item.innerHTML='<span class="dir-icon">'+icon+'</span>'+label;item.onclick=function(){selectMoveDir(path)};item.onmousedown=function(){selectMoveDir(path)};return item}
function loadDirTree(){var tree=document.getElementById('dirTree');tree.innerHTML='<div style="padding:12px;color:#9ca3af">加载中...</div>';
var url='/?__action=list_dirs&path='+encodeURI(currentDir);var xhr=new XMLHttpRequest();xhr.open('GET',url,true);xhr.onload=function(){try{var dirs=JSON.parse(xhr.responseText);if(!Array.isArray(dirs))dirs=[];tree.innerHTML='';tree.appendChild(makeDirItem('/','根目录','📁'));if(currentDir!=='/'){var parent=currentDir.replace(/[^\/]+\/$/,'/');var up=document.createElement('div');up.className='dir-item';up.innerHTML='<span class="dir-icon">📂</span>..';up.onclick=function(){navigateDir(parent)};tree.appendChild(up)}dirs.forEach(function(d){var name=d.replace(/\/$/,'').split('/').pop();tree.appendChild(makeDirItem(d,name,'📁'))});paintMoveSelection()}catch(e){tree.innerHTML='<div style="padding:12px;color:#ef4444">加载失败</div>'}};xhr.onerror=function(){tree.innerHTML='<div style="padding:12px;color:#ef4444">网络错误</div>'};xhr.send()}
function navigateDir(path){currentDir=path;loadDirTree()}
function selectMoveDir(path){moveTarget=path;document.getElementById('moveSelected').textContent='目标：'+path;paintMoveSelection()}
function doMove(){if(!moveTarget){showAlert('请选择目标目录');return}
var items=selectedItems.map(function(i){return i.name});api({action:'move',items:items,target:moveTarget,password:mgmtPwd},function(r){if(r.success){showToast('移动成功');setTimeout(function(){location.reload()},800)}else{showAlert(r.message||'移动失败')}})}
function showUpload(){if(!mgmtOn){showAlert('请先登录管理模式');return}document.getElementById('uploadModal').classList.add('show')}
function closeUpload(){if(uploading){if(confirm('正在上传，确定取消？')){uploadAbort&&uploadAbort();uploading=false}}document.getElementById('uploadModal').classList.remove('show');document.getElementById('fileInput').value='';document.getElementById('uploadFileName').textContent='点击选择文件';document.getElementById('uploadProgress').style.display='none';document.getElementById('progressFill').style.width='0';document.getElementById('uploadSubmitBtn').disabled=false}
function onFileSelect(input){if(input.files.length>0){var f=input.files[0];document.getElementById('uploadFileName').textContent=f.name+' ('+formatSize(f.size)+')'}}
function formatSize(b){if(b<1024)return b+'B';if(b<1048576)return(b/1024).toFixed(1)+'KB';if(b<1073741824)return(b/1048576).toFixed(1)+'MB';return(b/1073741824).toFixed(2)+'GB'}
function generateFileId(file){return file.name+'_'+file.size+'_'+file.lastModified}
function doUpload(){var input=document.getElementById('fileInput');if(!input.files||!input.files[0]){showAlert('请选择文件');return}
var file=input.files[0];var fileId=generateFileId(file);var totalChunks=Math.ceil(file.size/CHUNK_SIZE);var path=']]..path..[[';var pwd=sessionStorage.getItem('mgmtPwd')||'';
if(!pwd){showAlert('密码获取失败，请重新登录');return}
if(file.size<=10*1024*1024){var formData=new FormData();formData.append('file',file);formData.append('path',path);formData.append('password',pwd);
uploading=true;document.getElementById('uploadProgress').style.display='block';document.getElementById('uploadStatus').textContent='上传中...';document.getElementById('progressFill').style.width='50%';document.getElementById('uploadSubmitBtn').disabled=true;
var xhr=new XMLHttpRequest();xhr.open('POST','/__upload__',true);uploadAbort=function(){xhr.abort()};
xhr.onload=function(){uploading=false;document.getElementById('uploadSubmitBtn').disabled=false;if(xhr.responseText){try{var r=JSON.parse(xhr.responseText);if(r.success){document.getElementById('progressFill').style.width='100%';document.getElementById('uploadStatus').textContent='上传完成';showToast('上传成功');setTimeout(function(){closeUpload();location.reload()},800)}else{showAlert(r.message||'上传失败')}}catch(e){showAlert('上传失败')}}};xhr.onerror=function(){uploading=false;showAlert('网络错误')};xhr.send(formData);return}
uploading=true;document.getElementById('uploadProgress').style.display='block';document.getElementById('uploadSubmitBtn').disabled=true;
var uploadedChunks=[];var currentChunk=0;
function checkUploaded(){var formData=new FormData();formData.append('action','check');formData.append('file_id',fileId);formData.append('password',pwd);
var xhr=new XMLHttpRequest();xhr.open('POST','/__upload__',true);xhr.onload=function(){try{var r=JSON.parse(xhr.responseText);if(r.success){uploadedChunks=r.uploaded||[];currentChunk=0;uploadNext()}}catch(e){uploadNext()}};xhr.onerror=function(){uploadNext()};xhr.send(formData)}
function uploadNext(){if(!uploading)return;
while(currentChunk<totalChunks&&uploadedChunks.indexOf(currentChunk)!==-1){currentChunk++}
if(currentChunk>=totalChunks){mergeChunks();return}
var start=currentChunk*CHUNK_SIZE;var end=Math.min(start+CHUNK_SIZE,file.size);var chunk=file.slice(start,end);
var formData=new FormData();formData.append('action','chunk');formData.append('file_id',fileId);formData.append('chunk_index',currentChunk);formData.append('total_chunks',totalChunks);formData.append('filename',file.name);formData.append('path',path);formData.append('password',pwd);formData.append('file',chunk);
var xhr=new XMLHttpRequest();xhr.open('POST','/__upload__',true);uploadAbort=function(){xhr.abort();uploading=false};
var pct=Math.round((currentChunk/totalChunks)*100);document.getElementById('progressFill').style.width=pct+'%';document.getElementById('uploadStatus').textContent='上传中 '+pct+'% ('+(currentChunk+1)+'/'+totalChunks+')';
xhr.onload=function(){if(xhr.responseText){try{var r=JSON.parse(xhr.responseText);if(r.success){currentChunk++;uploadNext()}else{uploading=false;showAlert(r.message||'上传失败')}}catch(e){uploading=false;showAlert('上传失败')}}};xhr.onerror=function(){uploading=false;showAlert('网络错误，可重新上传继续')};xhr.send(formData)}
function mergeChunks(){document.getElementById('uploadStatus').textContent='合并文件中...';document.getElementById('progressFill').style.width='95%';
var formData=new FormData();formData.append('action','merge');formData.append('file_id',fileId);formData.append('password',pwd);
var xhr=new XMLHttpRequest();xhr.open('POST','/__upload__',true);xhr.onload=function(){uploading=false;document.getElementById('uploadSubmitBtn').disabled=false;try{var r=JSON.parse(xhr.responseText);if(r.success){document.getElementById('progressFill').style.width='100%';document.getElementById('uploadStatus').textContent='上传完成';showToast('上传成功');setTimeout(function(){closeUpload();location.reload()},800)}else{showAlert(r.message||'合并失败')}}catch(e){showAlert('合并失败')}};xhr.onerror=function(){uploading=false;showAlert('网络错误')};xhr.send(formData)}
checkUploaded()}
// 搜索功能
function filterList(){
  var keyword=document.getElementById('searchInput').value.toLowerCase();
  var items=document.querySelectorAll('.row-wrap');
  items.forEach(function(item){
    var name=item.getAttribute('data-name')||'';
    item.style.display=name.indexOf(keyword)!==-1?'flex':'none';
  });
}
// 排序功能
function sortList(mode){
  var container=document.querySelector('.card');
  var items=Array.from(container.querySelectorAll('.row-wrap'));
  document.querySelectorAll('.sort-bar span').forEach(function(s){s.classList.remove('active')});
  document.querySelector('[data-sort="'+mode+'"]').classList.add('active');
  if(mode==='name'){
    items.sort(function(a,b){return a.getAttribute('data-name').localeCompare(b.getAttribute('data-name'))});
  }else if(mode==='size'){
    items.sort(function(a,b){return(parseInt(b.getAttribute('data-size'))||0)-(parseInt(a.getAttribute('data-size'))||0)});
  }else{
    // 默认排序：目录在前，然后按名称
    items.sort(function(a,b){
      var aDir=a.querySelector('.ico.dir'),bDir=b.querySelector('.ico.dir');
      if(aDir&&!bDir)return -1;if(!aDir&&bDir)return 1;
      return a.getAttribute('data-name').localeCompare(b.getAttribute('data-name'));
    });
  }
  items.forEach(function(item){container.appendChild(item)});
}
</script>
</body>
</html>
]]
ngx.header.content_type = "text/html; charset=utf-8"
ngx.say(html)
