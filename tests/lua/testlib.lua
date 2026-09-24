local T = { passed = 0, failed = 0 }

function T.show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. T.show(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
    print("  ok   " .. name)
  else
    T.failed = T.failed + 1
    print("  FAIL " .. name .. "\n" .. tostring(err))
  end
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "not equal") .. ": expected " .. T.show(expected) .. ", got " .. T.show(actual), 2)
  end
end

function T.deepEq(actual, expected, msg)
  local a, e = T.show(actual), T.show(expected)
  if a ~= e then error((msg or "not deep-equal") .. ":\n  expected " .. e .. "\n  got      " .. a, 2) end
end

function T.errors(fn, substring)
  local ok, err = pcall(fn)
  if ok then error("expected an error", 2) end
  if substring and not tostring(err):find(substring, 1, true) then
    error("error " .. T.show(tostring(err)) .. " does not contain " .. T.show(substring), 2)
  end
end

function T.finish()
  print(("%d passed, %d failed"):format(T.passed, T.failed))
  if T.failed > 0 then error("TESTS FAILED", 0) end
end

return T
