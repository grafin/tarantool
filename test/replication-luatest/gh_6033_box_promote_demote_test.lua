local luatest = require('luatest')
local server = require('test.luatest_helpers.server')
local cluster = require('test.luatest_helpers.cluster')
local g_nspaces = luatest.group('gh-6033-box-promote-demote')
local g_unconfigured = luatest.group('gh-6033-box-promote-demote-unconfigured')
local g_spaces = luatest.group('gh-6033-box-promote-demote-with-spaces',
    {{engine = 'memtx'}, {engine = 'vinyl'}})

local promote_start = function(server)
    return server:exec(function()
        local f = require('fiber').new(box.ctl.promote)
        f:set_joinable(true)
        return f:id()
    end)
end

local demote_start = function(server)
    return server:exec(function()
        local f = require('fiber').new(box.ctl.demote)
        f:set_joinable(true)
        return f:id()
    end)
end

local fiber_join = function(server, fiber)
    return server:exec(function(fiber)
        return require('fiber').find(fiber):join()
    end, {fiber})
end

local wal_delay_start = function(server,  countdown)
    if countdown == nil then
        server:exec(function()
            box.error.injection.set('ERRINJ_WAL_DELAY', true)
        end)
    else
        server:exec(function(countdown)
            box.error.injection.set('ERRINJ_WAL_DELAY_COUNTDOWN', countdown)
        end, {countdown})
    end
end

local wal_delay_end = function(server)
    server:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
    end)
end

local cluster_init = function(g)
    g.cluster = cluster:new({})

    local engine = 'memtx'
    if g.params ~= nil and g.params.engine ~= nil then
        engine = g.params.engine
    end

    g.box_cfg = {
        election_mode = 'off',
        election_timeout = 0.5,
        read_only = false,
        replication_timeout = 0.1,
        replication_synchro_timeout = 5,
        replication_synchro_quorum = 1,
        replication = {
            server.build_instance_uri('server_1'),
            server.build_instance_uri('server_2'),
        },
    }

    g.server_1 = g.cluster:build_and_add_server(
        {alias = 'server_1', engine = engine, box_cfg = g.box_cfg})
    g.server_2 = g.cluster:build_and_add_server(
        {alias = 'server_2', engine = engine, box_cfg = g.box_cfg})
    g.cluster:start()
end

local cluster_reinit = function(g)
    g.server_1:wait_lsn(g.server_2)
    g.server_2:wait_lsn(g.server_1)

    g.server_1:box_config(g.box_cfg)
    g.server_2:box_config(g.box_cfg)
end

g_nspaces.before_all(cluster_init)
g_spaces.before_all(cluster_init)

g_nspaces.after_all(function(g) g.cluster:drop() end)
g_spaces.after_all(function(g) g.cluster:drop() end)

g_nspaces.after_each(cluster_reinit)
g_spaces.after_each(cluster_reinit)

-- Promoting/demoting should succeed if server is not configured.
g_unconfigured.test_unconfigured = function()
    local ok, err = pcall(box.ctl.promote)
    luatest.assert(ok, string.format(
        'error while promoting unconfigured server: %s', err))

    local ok, err = pcall(box.ctl.demote)
    luatest.assert(ok, string.format(
        'error while demoting unconfigured server: %s', err))
end

-- Promoting current raft leader and synchro queue owner should succeed
-- with elections enabled.
g_nspaces.test_leader_promote = function(g)
    g.server_1:box_config({election_mode = 'manual'})
    g.cluster:promote(g.server_1)

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(ok, string.format(
        'error while promoting leader with elections on: %s', err))

    g.server_1:box_config({election_mode = 'off'})
    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(ok, string.format(
        'error while promoting leader with elections off: %s', err))
end

g_nspaces.after_test('test_leader_promote', function(g)
    g.cluster:demote(g.server_1)
    g.server_2:wait_synchro_queue_owner_id(0)
end)

-- Demoting current follower should succeed.
g_nspaces.test_follower_demote = function(g)
    local ok, err = g.server_2:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(ok, string.format(
        'error while demoting follower with elections off: %s', err))

    g.server_1:box_config({election_mode = 'manual'})
    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(ok, string.format(
        'error while demoting follower with elections on: %s', err))
end

-- Promoting current raft leader should succeed,
-- even if he doesn't own synchro queue with elections enabled.
g_nspaces.test_raft_leader_promote = function(g)
    g.server_1:box_config({election_mode = 'manual'})

    -- Promote server, but get stuck before obtaining synchro queue
    -- (write term bump to wal, get stuck on promote)
    wal_delay_start(g.server_1, 2)
    g.server_1:exec(function()
        box.ctl.promote()
    end)
    g.server_1:wait_wal_delay()
    g.server_1:wait_election_state('leader')

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)

    luatest.assert(ok, string.format(
        'error while promoting raft leader: %s', err))
end

g_nspaces.after_test('test_raft_leader_promote', function(g)
    -- Finish promoting server_1
    wal_delay_end(g.server_1)
    g.server_1:wait_synchro_queue_owner_id()

    g.server_1:box_config({election_mode = 'off'})
    g.cluster:demote(g.server_1)
    g.server_2:wait_synchro_queue_owner_id(0)
end)

-- Promoting and demoting should work when everything is ok.
g_nspaces.test_ok = function(g)
    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    g.server_2:wait_synchro_queue_owner_id(g.server_1:instance_id())
    luatest.assert(ok, string.format(
        'error while promoting with elections off: %s', err))

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    g.server_2:wait_synchro_queue_owner_id(0)
    luatest.assert(ok, string.format(
        'error while demoting with elections off: %s', err))

    g.server_1:box_config({election_mode = 'manual'})

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    g.server_2:wait_synchro_queue_owner_id(g.server_1:instance_id())
    luatest.assert(ok, string.format(
        'error while promoting with elections on: %s', err))

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    g.server_2:wait_lsn(g.server_1)
    luatest.assert(ok, string.format(
        'error while demoting with elections on: %s', err))
end

g_nspaces.after_test('test_ok', function(g)
    -- Demoting server with election_mode ~= 'off' leaves it as limbo owner.
    -- https://github.com/tarantool/tarantool/issues/6860
    g.server_1:box_config({election_mode = 'off'})
    g.cluster:promote(g.server_2)
    g.cluster:demote(g.server_2)
    g.server_1:wait_synchro_queue_owner_id(0)
end)

-- Simultaneous promoting/demoting should fail.
g_nspaces.test_simultaneous = function(g)
    wal_delay_start(g.server_1)

    local wal_write_count = g.server_1:wal_write_count()
    g.f = promote_start(g.server_1)
    g.server_1:wait_wal_write_count(wal_write_count + 1)

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(not ok and err.code == box.error.UNSUPPORTED,
        'error while promoting while in promote')

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(not ok and err.code == box.error.UNSUPPORTED,
        'error while demoting while in promote')
end

g_nspaces.after_test('test_simultaneous', function(g)
    -- Finish already started promote
    wal_delay_end(g.server_1)
    fiber_join(g.server_1, g.f)
    g.f = nil
    g.cluster:demote(g.server_1)
    g.server_2:wait_synchro_queue_owner_id(0)
end)

-- Promoting voter should fail.
g_nspaces.test_voter_promote = function(g)
    g.server_1:box_config({election_mode = 'voter'})

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(not ok and err.code == box.error.UNSUPPORTED,
        'error while promoting voter')
end

-- Promoting should fail if it is interrupted from another server
-- while writing wal.
g_nspaces.test_wal_interfering_promote = function(g)
    -- Promote server_2, while server_1 is stuck.
    wal_delay_start(g.server_1)
    local wal_write_count = g.server_1:wal_write_count()
    g.server_2:promote()
    g.server_1:wait_wal_write_count(wal_write_count + 2)

    local election_term = g.server_1:election_term()
    local f = promote_start(g.server_1)
    g.server_1:wait_election_term(election_term + 1)

    wal_delay_end(g.server_1)
    local ok, err = fiber_join(g.server_1, f)

    luatest.assert(not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering promote not handled')
end

g_nspaces.after_test('test_wal_interfering_promote', function(g)
    -- server_1 incremented term and then failed it's promote.
    -- server_2 isn't leader in new term, but still limbo owner.
    g.cluster:promote(g.server_1)
    g.cluster:demote(g.server_1)
end)

-- Demoting should fail if it is interrupted from another server
-- while writing wal.
g_nspaces.test_wal_interfering_demote = function(g)
    g.cluster:promote(g.server_2)

    -- Promote server_1, while server_2 is stuck.
    wal_delay_start(g.server_2)
    local wal_write_count = g.server_2:wal_write_count()
    g.server_1:promote()
    g.server_2:wait_wal_write_count(wal_write_count + 2)

    local election_term = g.server_2:election_term()
    local f = demote_start(g.server_2)
    g.server_2:wait_election_term(election_term + 1)

    wal_delay_end(g.server_2)
    local ok, err = fiber_join(g.server_2, f)

    luatest.assert(not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering demote not handled')
end

g_nspaces.after_test('test_wal_interfering_demote', function(g)
    -- server_2 incremented term and then failed it's demote.
    -- server_1 isn't leader in new term, but still limbo owner.
    g.cluster:promote(g.server_2)
    g.cluster:demote(g.server_2)
end)

-- Promoting should fail if it is interrupted from another server
-- while waiting for synchro queue being emptied.
g_spaces.test_limbo_full_interfering_promote = function(g)
    -- Need 3 servers for this test:
    -- server_1 will try to promote with filled synchro queue,
    -- server_3 will interrupt server_1, while server_2 is leader
    local box_cfg = table.copy(g.box_cfg)
    box_cfg.replication = {
        server.build_instance_uri('server_1'),
        server.build_instance_uri('server_2'),
        server.build_instance_uri('server_3'),
    }

    local engine = 'memtx'
    if g.params ~= nil and g.params.engine ~= nil then
        engine = g.params.engine
    end

    local server_3 = g.cluster:build_server(
        {alias = 'server_3', engine = engine, box_cfg = g.box_cfg})
    server_3:start()
    g.server_1:box_config(box_cfg)
    g.server_2:box_config(box_cfg)

    g.cluster:promote(server_3)
    server_3:exec(function()
        box.schema.create_space('test', {
            is_sync = true, engine = os.getenv('TARANTOOL_ENGINE')
        }):create_index('pk')
    end)
    g.server_1:wait_lsn(server_3)
    g.server_2:wait_lsn(server_3)

    g.server_1:box_config({
        replication_synchro_quorum = 4,
        replication_synchro_timeout = 1000,
    })
    g.server_2:box_config({
        replication_synchro_timeout = 0.1,
    })
    server_3:box_config({
        replication_synchro_quorum = 4,
        replication_synchro_timeout = 1000,
    })

    -- Server_3 fills synchro queue and dies
    local lsn = server_3:lsn()
    server_3:exec(function()
        local s = box.space.test
        require('fiber').create(s.replace, s, {1}):id()
    end)
    g.server_1:wait_lsn(server_3, lsn + 1)
    g.server_2:wait_lsn(server_3, lsn + 1)

    -- Start promoting server_1 and interrupt it from server_2
    local f = promote_start(g.server_1)
    local election_term = g.server_2:election_term()
    g.server_2:exec(function()
        pcall(box.ctl.promote)
    end)
    server_3:wait_election_term(election_term + 1)
    g.server_1:wait_election_term(election_term + 1)
    --@TODO sometimes this causes assert on server_2
    -- src/box/txn_limbo.c:515: txn_limbo_read_promote:
    -- Assertion `txn_limbo_is_empty(&txn_limbo)' failed.
    -- https://github.com/tarantool/tarantool/issues/6842
    local ok, err = fiber_join(g.server_1, f)

    g.server_1:box_config({replication = g.box_cfg.replication})
    g.server_2:box_config({replication = g.box_cfg.replication})
    server_3:drop()

    luatest.assert(not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering promote not handled')
end

g_spaces.after_test('test_limbo_full_interfering_promote', function(g)
    g.cluster:promote(g.server_2)
    g.server_2:exec(function()
        box.space.test:drop()
    end)
    g.server_1:wait_lsn(g.server_2)
    g.cluster:demote(g.server_2)
end)

-- Demoting should fail if it is interrupted from another server
-- while waiting for synchro queue being emptied.
g_spaces.test_limbo_full_interfering_demote = function(g)
    g.cluster:promote(g.server_2)

    g.server_2:exec(function()
        box.schema.create_space('test', {
            is_sync = true, engine = os.getenv('TARANTOOL_ENGINE')
        }):create_index('pk')
    end)

    g.server_1:box_config({
        replication_synchro_timeout = 0.1,
    })

    g.server_2:box_config({
        replication_synchro_quorum = 3,
        replication_synchro_timeout = 1000,
    })

    local lsn = g.server_2:lsn()
    g.server_2:exec(function()
        local s = box.space.test
        require('fiber').create(s.replace, s, {1}):id()
    end)
    g.server_1:wait_lsn(g.server_2, lsn + 1)

    -- Start demoting server_2 and interrupt it from server_1
    local f = demote_start(g.server_2)
    local election_term = g.server_1:election_term()
    g.server_1:exec(function()
        pcall(box.ctl.promote)
    end)
    g.server_1:wait_election_term(election_term + 1)
    --@TODO sometimes this causes assert on server_2
    -- src/box/txn_limbo.c:515: txn_limbo_read_promote:
    -- Assertion `txn_limbo_is_empty(&txn_limbo)' failed.
    -- https://github.com/tarantool/tarantool/issues/6842
    local ok, err = fiber_join(g.server_2, f)

    luatest.assert(not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering demote not handled')
end

g_spaces.after_test('test_limbo_full_interfering_demote', function(g)
    g.cluster:promote(g.server_1)
    g.server_1:exec(function()
        box.space.test:drop()
    end)
    g.cluster:demote(g.server_1)
    g.server_2:wait_synchro_queue_owner_id(0)
end)

-- Promoting should fail if synchro queue replication timeouts during it
g_spaces.test_fail_limbo_ack_promote = function(g)
    g.server_1:box_config({
        replication_synchro_quorum = 3,
    })

    g.server_2:box_config({
        replication_synchro_quorum = 3,
        replication_synchro_timeout = 1000,
    })

    -- Fill synchro queue on server_1
    g.server_2:exec(function()
        box.ctl.promote()
        local s = box.schema.create_space('test', {
            is_sync = true, engine = os.getenv('TARANTOOL_ENGINE')
        })
        s:create_index('pk')
        require('fiber').create(s.replace, s, {1}):id()
    end)
    g.server_1:wait_lsn(g.server_2)

    -- Start promoting with default replication_synchro_timeout,
    -- wait until promote reaches waiting for limbo_acked,
    -- make it timeout by lowering replication_synchro_timeout
    local ok, err = g.server_1:exec(function()
        local fiber = require('fiber')
        local f = fiber.new(function() box.ctl.promote() end)
        f:set_joinable(true)
        box.cfg{replication_synchro_timeout = 0.01}
        return f:join()
    end)

    luatest.assert(not ok and err.code == box.error.QUORUM_WAIT,
        'wait quorum failure not handled')
end

g_spaces.after_test('test_fail_limbo_ack_promote', function(g)
    g.server_2:exec(function()
        -- Timeout for rollback
        box.cfg{replication_synchro_timeout = 0.001}
        -- Wait for rollback to happen
        require('fiber').sleep(0.01)
        -- Term was incremented by server_1, server_2 is not current leader.
        box.ctl.promote()
        -- Cleanup
        box.space.test:drop()
    end)
    g.server_1:wait_lsn(g.server_2)
    g.cluster:demote(g.server_2)
end)
