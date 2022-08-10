local util = require('vim.lsp.util')
local log = require('vim.lsp.log')
local api = vim.api
local M = {}

--- bufnr → true|nil
--- to throttle refreshes to at most one at a time
local active_refreshes = {}

--- bufnr -> lnum -> extmark
local extmarks_cache_by_buf = setmetatable({}, {
  __index = function(t, b)
    local key = b > 0 and b or api.nvim_get_current_buf()
    t[key] = {}

    return rawget(t, key)
  end,
})

--- bufnr -> client_id -> lenses
local lens_cache_by_buf = setmetatable({}, {
  __index = function(t, b)
    local key = b > 0 and b or api.nvim_get_current_buf()
    return rawget(t, key)
  end,
})

local namespaces = setmetatable({}, {
  __index = function(t, key)
    local value = api.nvim_create_namespace('vim_lsp_codelens:' .. key)
    rawset(t, key, value)
    return value
  end,
})

---@private
M.__namespaces = namespaces

---@private
local function execute_lens(lens, bufnr, client_id)
  local line = lens.range.start.line
  api.nvim_buf_clear_namespace(bufnr, namespaces[client_id], line, line + 1)

  local client = vim.lsp.get_client_by_id(client_id)
  assert(client, 'Client is required to execute lens, client_id=' .. client_id)
  local command = lens.command
  local fn = client.commands[command.command] or vim.lsp.commands[command.command]
  if fn then
    fn(command, { bufnr = bufnr, client_id = client_id })
    return
  end
  -- Need to use the client that returned the lens → must not use buf_request
  local command_provider = client.server_capabilities.executeCommandProvider
  local commands = type(command_provider) == 'table' and command_provider.commands or {}
  if not vim.tbl_contains(commands, command.command) then
    vim.notify(
      string.format(
        'Language server does not support command `%s`. This command may require a client extension.',
        command.command
      ),
      vim.log.levels.WARN
    )
    return
  end
  client.request('workspace/executeCommand', command, function(...)
    local result = vim.lsp.handlers['workspace/executeCommand'](...)
    M.refresh()
    return result
  end, bufnr)
end

--- Return all lenses for the given buffer
---
---@param bufnr number  Buffer number. 0 can be used for the current buffer.
---@return table (`CodeLens[]`)
function M.get(bufnr)
  local lenses_by_client = lens_cache_by_buf[bufnr or 0]
  if not lenses_by_client then
    return {}
  end
  local lenses = {}
  for _, client_lenses in pairs(lenses_by_client) do
    vim.list_extend(lenses, client_lenses)
  end
  return lenses
end

local function set_extmark(chunks, bufnr, i, ns, prev_extmarks)
  local id = prev_extmarks and prev_extmarks[i]
  local opts = {
    id = id,
    hl_mode = 'combine',
    virt_text = chunks,
  }

  if id then
    -- may raise 'line value outside range' outside range
    local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, i, 0, opts)
    if not ok then
      prev_extmarks[i] = nil
    end

    return
  end

  id = api.nvim_buf_set_extmark(bufnr, ns, i, 0, opts)
  prev_extmarks[i] = id
end

--- Run the code lens in the current line
---
function M.run()
  local line = api.nvim_win_get_cursor(0)[1]
  local bufnr = api.nvim_get_current_buf()
  local options = {}
  local lenses_by_client = lens_cache_by_buf[bufnr] or {}
  for client, lenses in pairs(lenses_by_client) do
    for _, lens in pairs(lenses) do
      if lens.range.start.line == (line - 1) then
        table.insert(options, { client = client, lens = lens })
      end
    end
  end
  if #options == 0 then
    vim.notify('No executable codelens found at current line')
  elseif #options == 1 then
    local option = options[1]
    execute_lens(option.lens, bufnr, option.client)
  else
    vim.ui.select(options, {
      prompt = 'Code lenses:',
      format_item = function(option)
        return option.lens.command.title
      end,
    }, function(option)
      if option then
        execute_lens(option.lens, bufnr, option.client)
      end
    end)
  end
end

function M.display_line(line, bufnr, client_id, prev_extmarks)
  local lenses_by_client = lens_cache_by_buf[bufnr]
  if not lenses_by_client then
    vim.notify('Codelens: tried to index lenses_by_client', vim.log.levels.ERROR)
    return
  end

  local lenses = lenses_by_client[client_id]

  local line_lenses = {}
  for _, lens in pairs(lenses) do
    if lens.range.start.line == line then
      table.insert(line_lenses, lens)
    end
  end
  M.display(line_lenses, bufnr, client_id, prev_extmarks)
end

--- Display the lenses using virtual text
---
---@param lenses table of lenses to display (`CodeLens[] | null`)
---@param bufnr number
---@param client_id number
function M.display(lenses, bufnr, client_id, prev_extmarks)
  if not lenses or not next(lenses) then
    return
  end
  local lenses_by_lnum = {}
  for _, lens in pairs(lenses) do
    local line_lenses = lenses_by_lnum[lens.range.start.line]
    if not line_lenses then
      line_lenses = {}
      lenses_by_lnum[lens.range.start.line] = line_lenses
    end
    table.insert(line_lenses, lens)
  end
  local ns = namespaces[client_id]
  for i, line_lenses in pairs(lenses_by_lnum or {}) do
    table.sort(line_lenses, function(a, b)
      return a.range.start.character < b.range.start.character
    end)
    local chunks = {}
    for j, lens in ipairs(line_lenses) do
      local text = lens.command and lens.command.title or 'Unresolved lens ...'
      table.insert(chunks, { text, 'LspCodeLens' })
      if j < #line_lenses then
        table.insert(chunks, { ' | ', 'LspCodeLensSeparator' })
      end
    end
    if #chunks > 0 then
      set_extmark(chunks, bufnr, i, ns, prev_extmarks)
    end
  end
end

--- Store lenses for a specific buffer and client
---
---@param lenses table of lenses to store (`CodeLens[] | null`)
---@param bufnr number
---@param client_id number
function M.save(lenses, bufnr, client_id)
  local lenses_by_client = lens_cache_by_buf[bufnr]
  if not lenses_by_client then
    lenses_by_client = {}
    lens_cache_by_buf[bufnr] = lenses_by_client
    local ns = namespaces[client_id]
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(_, b)
        lens_cache_by_buf[b] = nil
        extmarks_cache_by_buf[b] = nil
      end,
      on_lines = function(_, b, _, first_lnum, last_lnum)
        api.nvim_buf_clear_namespace(b, ns, first_lnum, last_lnum)
      end,
    })
  end
  lenses_by_client[client_id] = lenses
end

---@private
local function resolve_lenses(lenses, unresolved_lines, bufnr, client_id, callback, prev_extmarks)
  lenses = lenses or {}
  local num_lens = vim.tbl_count(lenses)
  if num_lens == 0 then
    callback()
    return
  end

  ---@private
  local function countdown()
    num_lens = num_lens - 1
    if num_lens == 0 then
      callback()
    end
  end

  -- We can't simply display line after resolve.
  -- If there exists a line with resolved lenses { a | b }. The next refresh call will eventually
  -- lead to the following sequence { a | b } -> { a | Unresolved } -> { a | c }, which flickers
  -- (regardless if c is equal to b or not).
  --
  -- We may update intermediate states if it's a new lens / the line hasn't been resolved yet.
  -- Otherwise, refresh when its lenses have been resolved.
  local num_lens_line = {}
  for _, lens in pairs(lenses) do
    local line = lens.range.start.line
    local c = num_lens_line[line] or 0
    num_lens_line[line] = c + 1
  end

  local function countdown_line(line)
    num_lens_line[line] = num_lens_line[line] - 1
    if unresolved_lines[line] or num_lens_line[line] == 0 then
      M.display_line(line, bufnr, client_id, prev_extmarks)
    end
  end

  local client = vim.lsp.get_client_by_id(client_id)
  for _, lens in pairs(lenses or {}) do
    if lens.command then
      countdown()
    else
      client.request('codeLens/resolve', lens, function(_, result)
        lens.command = result and result.command
        -- Incremental display.
        countdown_line(lens.range.start.line)
        countdown()
      end, bufnr)
    end
  end
end

local function diff(extmark, lnums)
  local invalid = {}
  local new = {}
  for k, _ in pairs(extmark) do
    if not lnums[k] then
      table.insert(invalid, k)
    end
  end

  for k, _ in pairs(lnums) do
    if not extmark[k] then
      new[k] = k
    end
  end

  return invalid, new
end

local function lenses_by_lnum(bufnr, client_id)
  if not lens_cache_by_buf[bufnr] then
    lens_cache_by_buf[bufnr] = {}
  end

  local lnum_with_lens = {}
  for _, lens in pairs(lens_cache_by_buf[bufnr][client_id] or {}) do
    lnum_with_lens[lens.range.start.line] = true
  end

  return lnum_with_lens
end

--- |lsp-handler| for the method `textDocument/codeLens`
---
function M.on_codelens(err, result, ctx, _)
  if err then
    active_refreshes[ctx.bufnr] = nil
    local _ = log.error() and log.error('codelens', err)
    return
  end

  local extmarks = extmarks_cache_by_buf[ctx.bufnr]

  M.save(result, ctx.bufnr, ctx.client_id)

  -- TODO pass lnums_with_lenses to first display call ?
  local invalid, new = diff(extmarks, lenses_by_lnum(ctx.bufnr, ctx.client_id))

  for _, line in pairs(invalid) do
    local id = extmarks[line]
    extmarks[line] = nil

    -- extmark might've changed position; if so, update our cache.
    local row, _ =
      unpack(api.nvim_buf_get_extmark_by_id(ctx.bufnr, namespaces[ctx.client_id], id, {}))
    if row then
      extmarks[row] = id
    end

    api.nvim_buf_clear_namespace(ctx.bufnr, namespaces[ctx.client_id], line, line + 1)
  end

  -- Display unresolved lenses and refresh them once resolved.
  if not next(extmarks) or #vim.tbl_keys(new) > 0 then
    local unresolved = {}
    for _, lens in pairs(result or {}) do
      local line = lens.range.start.line
      if new[line] then
        table.insert(unresolved, lens)
        api.nvim_buf_clear_namespace(ctx.bufnr, namespaces[ctx.client_id], line, line + 1)
      end
    end
    M.display(unresolved, ctx.bufnr, ctx.client_id, extmarks)
  end

  resolve_lenses(result, new, ctx.bufnr, ctx.client_id, function()
    active_refreshes[ctx.bufnr] = nil
  end, extmarks)
end

--- Refresh the codelens for the current buffer
---
--- It is recommended to trigger this using an autocmd or via keymap.
---
--- <pre>
---   autocmd BufEnter,CursorHold,InsertLeave <buffer> lua vim.lsp.codelens.refresh()
--- </pre>
---
function M.refresh()
  local params = {
    textDocument = util.make_text_document_params(),
  }
  local bufnr = api.nvim_get_current_buf()
  if active_refreshes[bufnr] then
    return
  end
  active_refreshes[bufnr] = true
  vim.lsp.buf_request(0, 'textDocument/codeLens', params, M.on_codelens)
end

return M
