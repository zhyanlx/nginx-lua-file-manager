local BASE_DIR = "/opt/www/download"
local PASSWORD = "change-me"
local UPLOAD_TEMP = "/tmp/upload_chunks"

os.execute("mkdir -p " .. UPLOAD_TEMP .. " 2>/dev/null")

ngx.req.read_body()
local body = ngx.req.get_body_data()

-- 大分片上传时，nginx/OpenResty 可能把 request body 写入临时文件，
-- 此时 get_body_data() 返回 nil，需要从 get_body_file() 读取。
if not body then
    local body_file = ngx.req.get_body_file()
    if body_file then
        local f = io.open(body_file, "rb")
        if f then
            body = f:read("*a")
            f:close()
        end
    end
end

if not body then
    ngx.say('{"success":false,"message":"无数据"}')
    return
end

local content_type = ngx.req.get_headers()["content-type"] or ""
local boundary = content_type:match("boundary=(.+)")
if not boundary then
    ngx.say('{"success":false,"message":"无效请求"}')
    return
end

-- 解析 multipart 数据
local function parse_multipart(body, boundary)
    local parts = {}
    local sep = "--" .. boundary
    local pos = 1
    while true do
        local start = body:find(sep, pos, true)
        if not start then break end
        local next_start = body:find(sep, start + #sep, true)
        if not next_start then break end
        local part = body:sub(start + #sep + 2, next_start - 3) -- +2 for \r\n, -3 for \r\n before boundary
        local header_end = part:find("\r\n\r\n", 1, true)
        if header_end then
            local headers = part:sub(1, header_end - 1)
            local content = part:sub(header_end + 4)
            local name = headers:match('name="([^"]+)"')
            local filename = headers:match('filename="([^"]+)"')
            parts[#parts + 1] = {
                name = name,
                filename = filename,
                content = content
            }
        end
        pos = next_start
    end
    return parts
end

local parts = parse_multipart(body, boundary)
local params = {}

for _, part in ipairs(parts) do
    if part.name then
        params[part.name] = part.content
    end
    if part.filename then
        -- 分片上传时前端 file.slice() 产生 Blob，浏览器默认 multipart filename 可能是 "blob"。
        -- 不要让这个默认名覆盖前面显式传入的真实 filename 字段。
        if not params["filename"] or params["filename"] == "" then
            params["filename"] = part.filename
        end
        params["file_data"] = part.content
    end
end

local password = params.password
local action = params.action or "upload"

if password ~= PASSWORD then
    ngx.say('{"success":false,"message":"未授权"}')
    return
end

-- 获取上传路径
local path = params.path or "/"
path = path:gsub("%.%.",""):gsub("[^%w%_%-%./]","")
if path:sub(-1) ~= "/" then path = path .. "/" end

-- 检查上传状态（断点续传）
if action == "check" then
    local file_id = params.file_id
    if not file_id then
        ngx.say('{"success":false,"message":"缺少文件ID"}')
        return
    end
    local chunk_dir = UPLOAD_TEMP .. "/" .. file_id
    local info_file = chunk_dir .. "/info.json"
    local f = io.open(info_file, "r")
    if f then
        local info = f:read("*a")
        f:close()
        -- 列出已上传的分片
        local chunks = {}
        local p = io.popen('ls "' .. chunk_dir .. '/" 2>/dev/null')
        if p then
            for line in p:lines() do
                local num = line:match("^chunk(%d+)$")
                if num then
                    chunks[#chunks + 1] = tonumber(num)
                end
            end
            p:close()
        end
        local cjson = require("cjson")
        ngx.say('{"success":true,"uploaded":' .. cjson.encode(chunks) .. '}')
    else
        ngx.say('{"success":true,"uploaded":[]}')
    end
    return
end

-- 上传分片
if action == "chunk" then
    local file_id = params.file_id
    local chunk_index = tonumber(params.chunk_index)
    local total_chunks = tonumber(params.total_chunks)
    local file_name = params.filename

    if not file_id or not chunk_index or not file_name then
        ngx.say('{"success":false,"message":"参数不完整"}')
        return
    end

    local chunk_dir = UPLOAD_TEMP .. "/" .. file_id
    os.execute("mkdir -p \"" .. chunk_dir .. "\" 2>/dev/null")

    -- 保存分片
    local chunk_file = chunk_dir .. "/chunk" .. chunk_index
    local f = io.open(chunk_file, "wb")
    if not f then
        ngx.say('{"success":false,"message":"保存分片失败"}')
        return
    end
    f:write(params.file_data)
    f:close()

    -- 保存文件信息
    local info_file = chunk_dir .. "/info.json"
    local info_f = io.open(info_file, "w")
    if info_f then
        info_f:write('{"name":"' .. file_name .. '","total":' .. total_chunks .. ',"path":"' .. path .. '"}')
        info_f:close()
    end

    ngx.say('{"success":true,"chunk":' .. chunk_index .. '}')
    return
end

-- 合并分片
if action == "merge" then
    local file_id = params.file_id
    if not file_id then
        ngx.say('{"success":false,"message":"缺少文件ID"}')
        return
    end

    local chunk_dir = UPLOAD_TEMP .. "/" .. file_id
    local info_file = chunk_dir .. "/info.json"

    -- 读取文件信息
    local f = io.open(info_file, "r")
    if not f then
        ngx.say('{"success":false,"message":"找不到上传信息"}')
        return
    end
    local info = f:read("*a")
    f:close()

    local cjson = require("cjson")
    local ok, data = pcall(cjson.decode, info)
    if not ok then
        ngx.say('{"success":false,"message":"上传信息损坏"}')
        return
    end

    local file_name = data.name
    local total_chunks = data.total
    local upload_path = data.path or path

    -- 合并文件
    local full_path = BASE_DIR .. upload_path .. file_name
    local out = io.open(full_path, "wb")
    if not out then
        ngx.say('{"success":false,"message":"创建文件失败"}')
        return
    end

    for i = 0, total_chunks - 1 do
        local chunk_file = chunk_dir .. "/chunk" .. i
        local cf = io.open(chunk_file, "rb")
        if cf then
            local content = cf:read("*a")
            cf:close()
            out:write(content)
        end
    end
    out:close()

    -- 清理临时文件
    os.execute("rm -rf \"" .. chunk_dir .. "\" 2>/dev/null")

    ngx.say('{"success":true,"message":"上传完成"}')
    return
end

-- 普通上传（兼容小文件）
local file_name = params.filename
local file_data = params.file_data

if not file_name or file_name == "" then
    ngx.say('{"success":false,"message":"请选择文件"}')
    return
end

local full_path = BASE_DIR .. path .. file_name
local f = io.open(full_path, "wb")
if not f then
    ngx.say('{"success":false,"message":"保存失败"}')
    return
end
f:write(file_data)
f:close()

ngx.say('{"success":true,"message":"上传成功"}')
