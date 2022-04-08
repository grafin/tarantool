local fiber = require('fiber')
local luatest = require('luatest')
local cluster = require('test.luatest_helpers.cluster')
local server = require('test.luatest_helpers.server')
local g_async = luatest.group('fencing_async', {
    {election_mode = 'manual'}, {election_mode = 'candidate'}})
local g_sync = luatest.group('fencing_sync')

local SHORT_TIMEOUT = 0.1
local LONG_TIMEOUT = 1000
local DEATH_TIMEOUT = 2 * SHORT_TIMEOUT

local function promote(server)
    luatest.helpers.retrying({}, function()
        return server:exec(function()
            pcall(box.ctl.promote)
            if box.info.election.state ~= 'leader' then
                return false
            end
            if box.info.synchro.queue.owner ~= box.info.id then
                return false
            end
            return true
        end)
    end)
end

local function wait_sync(leader, servers)
    local vclock = leader:get_vclock()
    vclock[0] = nil
    for _, server in ipairs(servers) do
        server:wait_vclock(vclock)
    end
end

local function wait_disconnected(node_1, node_2)
    luatest.helpers.retrying({}, function()
        node_1:exec(function(i)
            return (box.info.replication[i].downstream.status == 'stopped' or
                    box.info.replication[i].upstream == nil)
        end, {node_2:instance_id()})
    end)
end

local function wait_connected(node_1, node_2)
    luatest.helpers.retrying({}, function()
        node_1:exec(function(i)
            return (box.info.replication[i].downstream.status == 'follow' and
                    box.info.replication[i].upstream.status == 'follow')
        end, {node_2:instance_id()})
    end)
end

local function test_rw(server)
    return server:exec(function()
        return pcall(box.space.test.replace, box.space.test, {1})
    end)
end

local function box_cfg_update(servers, cfg)
    for _, server in ipairs(servers) do
        server:exec(function(cfg) box.cfg(cfg) end, {cfg})
    end
end

local function start(g)
    g.box_cfg = {
        election_mode = 'manual',
        election_timeout = SHORT_TIMEOUT,
        replication = {
            server.build_instance_uri('server_1'),
            server.build_instance_uri('server_2'),
            server.build_instance_uri('server_3'),
        },
        replication_connect_quorum = 1,
        replication_synchro_quorum = 2,
        replication_synchro_timeout = SHORT_TIMEOUT,
        replication_timeout = SHORT_TIMEOUT,
    }

    g.cluster = cluster:new({})
    g.server_1 = g.cluster:build_and_add_server(
        {alias = 'server_1', box_cfg = g.box_cfg})

    g.box_cfg.read_only = true
    g.server_2 = g.cluster:build_and_add_server(
        {alias = 'server_2', box_cfg = g.box_cfg})
    g.server_3 = g.cluster:build_and_add_server(
        {alias = 'server_3', box_cfg = g.box_cfg})

    g.cluster:start()
    g.cluster:wait_fullmesh()
    promote(g.server_1)
    wait_sync(g.server_1, g.cluster.servers)
end

local function stop(g)
    g.server_2:stop()
    g.server_3:stop()
    g.server_1:stop()
end

g_async.before_all(start)
g_async.after_all(stop)

g_async.after_each(function(g)
    box_cfg_update(g.cluster.servers, {replication = g.box_cfg.replication})
    wait_connected(g.server_1, g.server_2)
    wait_connected(g.server_1, g.server_3)
    promote(g.server_1)
    wait_sync(g.server_1, g.cluster.servers)
    g.server_1:exec(function() box.space.test:drop() end)
    wait_sync(g.server_1, g.cluster.servers)
    box_cfg_update({g.server_1}, {replication = {}})
end)

g_async.test_fencing = function(g)
    box_cfg_update({g.server_1}, {election_mode = g.params.election_mode})
    g.server_1:exec(function()
        box.schema.create_space('test'):create_index('pk')
    end)
    wait_sync(g.server_1, g.cluster.servers)

    -- Leader is rw on test start
    local ok, err = test_rw(g.server_1)
    luatest.assert(ok, ('Leader is rw while having quorum: %s'):format(err))

    -- Disconnect one replica, leader is still rw.
    box_cfg_update({g.server_2}, {replication = {}})
    wait_disconnected(g.server_1, g.server_2)
    local ok, err = test_rw(g.server_1)
    luatest.assert(ok, ('Leader is rw while having quorum: %s'):format(err))

    -- Disconnect second replica, leader must become ro because of quorum loss.
    -- Fencing is on by default.
    box_cfg_update({g.server_3}, {replication = {}})
    wait_disconnected(g.server_1, g.server_3)
    fiber.sleep(DEATH_TIMEOUT)
    local ok, err = test_rw(g.server_1)
    luatest.assert(not ok and err.code == box.error.READONLY,
        'Leader is ro after quorum loss')

    -- Connect one replica back and check, that leader (maybe different server)
    -- is rw once again.
    box_cfg_update({g.server_2}, {replication = g.box_cfg.replication})
    wait_connected(g.server_1, g.server_2)
    wait_sync(g.server_1, {g.server_2})
    if g.box_cfg.election_mode == 'manual' then
        promote(g.server_1)
    end
    g.server_2:wait_election_leader_found()
    wait_sync(g.server_1, {g.server_2})
    local ok, err = test_rw(g.server_1)
    luatest.assert(ok, ('Leader is rw after regaining quorum: %s'):format(err))

    -- Turn off fencing, disconnect both replicas,
    -- Leader must not become ro even after quorum loss.
    box_cfg_update({g.server_1}, {election_fencing = false})
    box_cfg_update({g.server_2}, {replication = {}})
    wait_disconnected(g.server_1, g.server_2)
    fiber.sleep(DEATH_TIMEOUT)
    local ok = test_rw(g.server_1)
    luatest.assert(ok, 'Leader is rw after quorum loss')

    -- Turning on fencing on leader when quorum is allready lost must make it ro
    box_cfg_update({g.server_1}, {election_fencing = true})
    local ok, err = test_rw(g.server_1)
    luatest.assert(not ok and err.code == box.error.READONLY,
        'Leader is ro after quorum loss')
end

g_sync.before_all(start)
g_sync.after_all(stop)

g_sync.test_fencing = function(g)
    box_cfg_update(g.cluster.servers, {read_only = false})
    g.server_1:exec(function()
        box.schema.create_space('test', {is_sync = true}):create_index('pk')
        box.cfg{election_mode = 'candidate'}
    end)

    box_cfg_update({g.server_1}, {
        election_fencing = false,
        replication_synchro_timeout = LONG_TIMEOUT,
    })

    box_cfg_update({g.server_2, g.server_3}, {replication = {}})
    wait_disconnected(g.server_1, g.server_2)
    wait_disconnected(g.server_1, g.server_3)

    local leader, limbo_len = g.server_1:exec(function(t)
        require('fiber').sleep(t)
        return box.info.election.leader, box.info.synchro.queue.len
    end, {DEATH_TIMEOUT})
    luatest.assert_equals(leader, 1)
    luatest.assert_equals(limbo_len, 0)

    g.server_1:exec(function()
        require('fiber').create(function() box.space.test:replace{1} end)
    end)

    -- Enabling fencing leads to leader resign.
    box_cfg_update({g.server_1}, {election_fencing = true})
    box_cfg_update({g.server_1}, {replication_synchro_timeout = SHORT_TIMEOUT})

    -- Fenced leader must not CONFIRM/ROLLBACK unfinished synchronous
    -- transactions.
    local leader, limbo_len = g.server_1:exec(function(t)
        require('fiber').sleep(t)
        return box.info.election.leader, box.info.synchro.queue.len
    end, {DEATH_TIMEOUT})
    luatest.assert_equals(leader, 0)
    luatest.assert_equals(limbo_len, 1)

    -- After regaining quorum and becoming leader once again old leader must
    -- replicate previously "frozen" synchronous transactions and confirm them.
    box_cfg_update({g.server_2}, {replication = g.box_cfg.replication})
    wait_connected(g.server_1, g.server_2)
    g.server_1:wait_election_leader()
    wait_sync(g.server_1, {g.server_2})
    luatest.helpers.retrying({}, function()
        g.server_1:exec(function()
            return box.info.synchro.queue.len == 0
        end)
    end)

    local ret = g.server_1:exec(function()
        return box.space.test:select{1}
    end)
    luatest.assert_equals(ret, {{1}},
        'Sync write confirmed after leadership regain')

    box_cfg_update({g.server_1}, {
        election_fencing = false,
        election_timeout = LONG_TIMEOUT,
        replication_timeout = LONG_TIMEOUT,
        replication_synchro_timeout = LONG_TIMEOUT,
    })

    box_cfg_update({g.server_1}, {replication = {
        g.server_1.net_box_uri,
    }})
    box_cfg_update({g.server_2, g.server_3}, {replication = {
        g.server_2.net_box_uri,
        g.server_3.net_box_uri,
    }})
    luatest.helpers.retrying({}, function()
        g.server_1:exec(function()
            return (box.info.replication[2].upstream == nil and
                    box.info.replication[3].upstream == nil and
                    box.info.replication[2].downstream.status == 'stopped' and
                    box.info.replication[3].downstream.status == 'stopped')
        end)
    end)
    wait_connected(g.server_2, g.server_3)

    local leader, limbo_len = g.server_1:exec(function(t)
        require('fiber').sleep(t)
        return box.info.election.leader, box.info.synchro.queue.len
    end, {DEATH_TIMEOUT})
    luatest.assert_equals(leader, 1)
    luatest.assert_equals(limbo_len, 0)

    g.server_1:exec(function()
        require('fiber').create(function() box.space.test:replace{2} end)
    end)

    box_cfg_update({g.server_1}, {election_fencing = true})
    box_cfg_update({g.server_1}, {replication_synchro_timeout = SHORT_TIMEOUT})

    local leader, limbo_len = g.server_1:exec(function(t)
        require('fiber').sleep(t)
        return box.info.election.leader, box.info.synchro.queue.len
    end, {DEATH_TIMEOUT})
    luatest.assert_equals(leader, 0)
    luatest.assert_equals(limbo_len, 1)
    box_cfg_update({g.server_2}, {election_mode = 'candidate'})

    promote(g.server_2)
    box_cfg_update(g.cluster.servers, {replication = g.box_cfg.replication})

    -- If a new leader was elected while old one was fenced - "frozen"
    -- transactions should be rollbacked by new leader.
    luatest.helpers.retrying({}, function()
        g.server_1:exec(function()
            return box.info.synchro.queue.len == 0
        end)
    end)

    wait_sync(g.server_2, {g.server_1})
    local ret = g.server_1:exec(function()
        return box.space.test:select{2}
    end)
    luatest.assert_equals(ret, {},
        'Sync write rollbacked after new leader discovered')
end
