netbox = require('net.box')
--
-- gh-2763: when credentials of a user are updated, it should be
-- reflected in all his sessions and objects.
--

box.schema.user.create('test_user', {password = '1'})
function test1() return 'success' end

conns = {}
for i = 1, 10 do                                                    \
    local c                                                         \
    if i % 2 == 0 then                                              \
        c = netbox.connect(                                         \
            box.cfg.listen, {user = 'test_user', password = '1'})   \
    else                                                            \
        c = netbox.connect(box.cfg.listen)                          \
    end                                                             \
    local ok, err = pcall(c.call, c, 'test1')                       \
    assert(not ok and err.code == box.error.ACCESS_DENIED)          \
    table.insert(conns, c)                                          \
end

box.schema.user.grant('test_user', 'execute', 'universe')
box.schema.user.grant('guest', 'execute', 'universe')
-- Succeeds without a reconnect.
for _, c in pairs(conns) do                                         \
    assert(c:call('test1') == 'success')                            \
    c:close()                                                       \
end

box.schema.user.revoke('guest', 'execute', 'universe')
box.schema.user.drop('test_user')
