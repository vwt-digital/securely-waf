require "apache2"
local http = require("socket.http")
local urlhelper = require("urlhelper")
local mime = require("mime")
local json = require("json")

local metadataIdentity = "http://metadata/computeMetadata/v1/instance/service-accounts/default/identity"

local jwt_cache = {} -- cache per upstream service

function split(str, sep)
    local parts = {}
    if str then
        for m in str:gmatch('[^'..sep..']+') do
            parts[#parts + 1] = m
        end
    end
    return parts
end

function create_audience_map()
    local audiences = split(os.getenv('GCP_IAM_AUDIENCES'), ',')
    local fqdns = split(os.getenv('FQDN'), ',')
    local map = {}
    for i, k in pairs(fqdns) do
        map[k] = audiences[i]
    end
	return map
end

local audience_map = create_audience_map()

function get_token(upstream)
    local response_body = {}

    local audience = audience_map[upstream]

    if audience == nil then
        audience = upstream
    end

    http.request {
        url = metadataIdentity .. "?audience=" .. urlhelper.urlencode(audience),
        sink = ltn12.sink.table(response_body),
        headers = {
            ["Metadata-Flavor"] = "Google"
        }
    }

    print('DEBUG GCP IAM token audience for [' .. upstream .. '] is [' .. audience .. ']')
    return table.concat(response_body)
end

function jwt_part_to_base64(jwt_part)
    local reminder = #jwt_part % 4

    if reminder > 0 then
        local padlen = 4 - reminder
        jwt_part = jwt_part .. string.rep('=', padlen)
    end

    return jwt_part:gsub('-', '+'):gsub('_', '/')
end

function get_jwt_payload(jwt)
    local jwt_payload_part = string.match(jwt, "%.(.*)%.")

    local b63_encoded_payload = jwt_part_to_base64(jwt_payload_part)

    return json.decode((mime.unb64(b63_encoded_payload)))
end

function get_upstream(r)
    return r.headers_in['Host']
end

function update_jwt_cache(upstream)
    print("INFO getting new JWT token for service " .. upstream)
    local token = get_token(upstream)

    jwt_cache_entry = {}
    jwt_cache_entry.token = token
    jwt_cache_entry.payload = get_jwt_payload(token)
    jwt_cache[upstream] = jwt_cache_entry

    print("INFO JWT token for service " .. upstream .. " refreshed until " .. jwt_cache[upstream].payload.exp)
end

function authenticate(r)
    local upstream = get_upstream(r)
    local current_time = os.time(os.date("!*t"))

    if jwt_cache[upstream] ~= nil then
        if jwt_cache[upstream].payload.exp - 60 * 5 <= current_time then
            update_jwt_cache(upstream)
        else
            print("DEBUG serving request to " .. upstream .. " from JWT cache")
        end
    else
        print("INFO requesting initial token for service " .. upstream)
        update_jwt_cache(upstream)
    end

    r.headers_in['X-Cloud-Authorization'] = jwt_cache[upstream].token

    if os.getenv('GCP_IAM_AUDIENCES') ~= nil then
        if not audience_map[upstream] or audience_map[upstream] ~= '-' then
            if r.headers_in['Authorization'] ~= nil then
                r.headers_in['X-Orig-Auth'] = r.headers_in['Authorization']
            end
            r.headers_in['Authorization'] = 'Bearer ' .. r.headers_in['X-Cloud-Authorization']
            print("DEBUG GCP IAM Auth header [" .. r.headers_in['Authorization'] .. "]")
        else
            print("DEBUG Disabled GCP IAM_AUTH for [" .. upstream .. "]")
        end
    end

    return apache2.DECLINED -- let the proxy handler do this instead
end
