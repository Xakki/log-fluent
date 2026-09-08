-- Наличие cjson проверяется в том же Fluent Bit image, который используется collector.
local cjson = require("cjson")

function json_decoder_probe(tag, ts, record)
    local decoded = cjson.decode('{"identity_opaque":true}')
    if decoded["identity_opaque"] ~= true then
        error("cjson boolean decode failed")
    end

    return 0, ts, record
end
