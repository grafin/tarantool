local fiber = require('fiber')
local luatest = require('luatest')
local server = require('luatest.server')
local cluster = require('luatest.replica_set')
local group = luatest.group('gh-3442-persist-gc-state')

local RETRY_TIMEOUT = 5
local RETRY_DELAY = 0.1

local function insert_data()
    box.space.test:insert({box.space.test:count() + 1})
end

local function get_data_count()
    return box.space.test:count()
end

local function wait_sync(servers)
    for _, server_1 in ipairs(servers) do
        for _, server_2 in ipairs(servers) do
            if server_1 ~= server_2 then
                server_1:wait_for_election_term(server_2:get_election_term())
                server_1:wait_for_vclock_of(server_2)
            end
        end
    end
end

local function cluster_init(g)
    g.cluster = cluster:new({})

    g.box_cfg = {
        election_mode = 'off',
        replication_connect_quorum = 2,
        checkpoint_interval = 0.1,
        checkpoint_count = 1,
        wal_cleanup_delay = 0.1,
        replication = {
            server.build_listen_uri('server_1'),
            server.build_listen_uri('server_2'),
        },
    }

    g.box_cfg.instance_uuid = luatest.helpers.uuid('1')
    g.server_1 = g.cluster:build_and_add_server(
        {alias = 'server_1', box_cfg = g.box_cfg})

    g.box_cfg.instance_uuid = luatest.helpers.uuid('2')
    g.server_2 = g.cluster:build_and_add_server(
        {alias = 'server_2', box_cfg = g.box_cfg})

    g.cluster:start()
    g.cluster:wait_for_fullmesh()

    g.server_1:exec(function()
        box.schema.create_space('test'):create_index('pk')
    end)

    wait_sync(g.cluster.servers)
end

group.before_all(cluster_init)
group.after_all(function(g) g.cluster:stop() end)

group.test_persistent_gc_state = function(g)
    g.server_2:stop()

    g.server_1.box_cfg.replication_connect_quorum = 1
    g.server_1:restart()
    g.server_1:wait_until_ready()

    g.server_1:exec(insert_data)

    -- Wait for gc to start.
    luatest.helpers.retrying({}, function()
        luatest.assert(g.server_1:grep_log('wal/engine cleanup is resumed'))
    end)

    -- Prevent server_2 from automatically reboostraping from server_1
    -- This can also happen with 3 servers, if replication_connect_quorum is 2
    -- and server_1 has no connection to server_2 and server_3 during their
    -- startup.
    g.server_2.box_cfg.replication_connect_quorum = 1
    g.server_2.box_cfg.replication = {
        server.build_listen_uri('server_2'),
    }
    g.server_2:start()

    g.server_2:exec(function(config)
        box.cfg(config)
    end, {g.box_cfg})

    g.server_1:exec(insert_data)

    local data_count = g.server_1:exec(get_data_count)
    local timeout = fiber.clock() + RETRY_TIMEOUT
    while g.server_2:exec(get_data_count) ~= data_count do
        luatest.assert_lt(fiber.clock(), timeout, 'server_2 synced')
        luatest.assert_not(g.server_2:grep_log('XlogGapError'))
        fiber.sleep(RETRY_DELAY)
    end

    luatest.assert_not(
        g.server_2:grep_log('initiating rebootstrap'),
        'server_2 did not automatically rebootstrap')
end
