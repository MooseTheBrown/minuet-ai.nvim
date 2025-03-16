local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'
local Job = require 'plenary.job'
local uv = vim.uv or vim.loop

local function generate_uuid_v4()
    local math = require('math')
    math.randomseed(require('os').time())

    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local uuid = template:gsub('[xy]', function(c)
        local v = math.random(0, 15)
        if c == 'x' then
            return string.format('%x', v)
        else
            return string.format('%x', (v % 4) + 8)
        end
    end)
    return uuid
end

local M = {
    token = '',
    last_update_time = 0,
}

M.is_available = function()
    local config = require('minuet').config
    local options = config.provider_options.gigachat
    if options.end_point == '' or options.api_key == '' or options.name == '' then
        return false
    end

    return true
end

if not M.is_available() then
    utils.notify(
        'API key, name or end point have not been set',
        'error',
        vim.log.levels.ERROR
    )
end

M.prompt = function(context_before_cursor, context_after_cursor)
    local utils = require 'minuet.utils'
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    local prompt = [[
Работай в режиме автодополнения кода. Пояснений не нужно, пиши только код.
]]
    return language .. '\n' .. tab .. '\n' .. prompt .. context_before_cursor
end

M.request_token = function(endpoint, api_key, name)
    local args = {
        '-L',
        endpoint,
        '-H',
        'Content-Type: application/x-www-form-urlencoded',
        '-H',
        'Accept: application/json',
        '-H',
        'RqUID: ' .. generate_uuid_v4(),
        '-H',
        'Authorization: Basic ' .. api_key,
        '--data-urlencode',
        'scope=GIGACHAT_API_PERS',
    }

    local new_job = Job:new {
        command = 'curl',
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            local result

            result = utils.no_stream_decode(job, exit_code, '', name, function(json)
                return json.access_token
            end)

            if result then
                M.token = result
                M.last_update_time = require('os').time()
            end
        end),
    }

    common.register_job(new_job)
    new_job:start()
end

M.get_token = function(endpoint, api_key, name)
    local now = require('os').time()

    if M.token == '' or (now - M.last_update_time) >= 1800 then
        M.request_token(endpoint, api_key, name)
    end

    return M.token
end

M.get_text_fn = function(json)
    return json.choices[1].message.content
end

M.complete = function(context, callback)
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.gigachat)

    common.terminate_all_jobs()

    local data = {}

    data.model = options.model
    data.stream = options.stream
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local prompt = M.prompt(context_before_cursor, context_after_cursor)

    data.messages = {
        {
            role = 'user',
            content = prompt
        },
    }

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local items = {}
    local args = {
        '-L',
        options.end_point,
        '-H',
        'Content-Type: application/json',
        '-H',
        'Accept: application/json',
        '-H',
        'Authorization: Bearer ' .. M.get_token(options.auth_end_point, options.api_key, options.name),
        '-d',
        '@' .. data_file,
    }

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    local new_job = Job:new {
        command = 'curl',
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            local result

            if options.stream then
                result = utils.stream_decode(job, exit_code, data_file, options.name, M.get_text_fn)
            else
                result = utils.no_stream_decode(job, exit_code, data_file, options.name, M.get_text_fn)
            end

            if result then
               table.insert(items, result)
            end

            items = common.filter_context_sequences_in_items(items, context_after_cursor)
            items = utils.remove_spaces(items)
            callback(items)
        end),
    }

    common.register_job(new_job)
    new_job:start()
end

return M
