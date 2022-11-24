env = require('test_run')
test_run = env.new()

--
-- gh-5806: this replica_rejoin test relies on the wal cleanup fiber
-- been disabled thus lets turn it off explicitly every time we restart
-- the main node.
box.cfg{wal_cleanup_delay = 0}

--
-- gh-461: check that garbage collection works as expected
-- after rebootstrap.
--
box.schema.user.grant('guest', 'replication')
_ = box.schema.space.create('mem')
_ = box.space.mem:create_index('pk', {parts = {1, 'string'}})
_ = box.schema.space.create('test', { id = 9000, engine = 'vinyl' })
_ = box.space.test:create_index('pk')
pad = string.rep('x', 12 * 1024)
for i = 1, 100 do box.space.test:replace{i, pad} end
box.snapshot()

-- Join a replica. Check its files.
test_run:cmd("create server replica with rpl_master=default, script='vinyl/replica_rejoin.lua'")
test_run:cmd("start server replica")
files = test_run:eval("replica", "fio = require('fio') return fio.glob(fio.pathjoin(box.cfg.vinyl_dir, box.space.test.id, 0, '*'))")[1]
_ = box.space.mem:replace{'files', files}
test_run:cmd("stop server replica")

-- Invoke garbage collector on the master.
_ = box.space._gc_consumers:delete(2)
test_run:cmd("restart server default")
box.cfg{wal_cleanup_delay = 0}
checkpoint_count = box.cfg.checkpoint_count
box.cfg{checkpoint_count = 1}
box.space.test:delete(1)
box.snapshot()
box.cfg{checkpoint_count = checkpoint_count}

-- Rebootstrap the replica. Check that old files are removed
-- by garbage collector.
test_run:cmd("start server replica")
test_run:cmd("switch replica")
box.cfg{checkpoint_count = 1}
box.snapshot()
box.space.test:count() -- 99
test_run:cmd("switch default")
files = box.space.mem:get('files')[2]
ok = true
fio = require('fio')
for _, f in ipairs(files) do ok = ok and not fio.path.exists(f) end
ok
files = test_run:eval("replica", "fio = require('fio') return fio.glob(fio.pathjoin(box.cfg.vinyl_dir, box.space.test.id, 0, '*'))")[1]
_ = box.space.mem:replace{'files', files}
test_run:cmd("stop server replica")

-- Invoke garbage collector on the master.
_ = box.space._gc_consumers:delete(2)
test_run:cmd("restart server default")
box.cfg{wal_cleanup_delay = 0}
checkpoint_count = box.cfg.checkpoint_count
box.cfg{checkpoint_count = 1}
box.space.test:delete(2)
box.snapshot()
box.cfg{checkpoint_count = checkpoint_count}

-- Make the master fail join after sending data. Check that
-- files written during failed rebootstrap attempt are removed
-- by garbage collector.
box.error.injection.set('ERRINJ_RELAY_FINAL_JOIN', true)
test_run:cmd("start server replica with crash_expected=True") -- fail
test_run:cmd("start server replica with crash_expected=True") -- fail again
test_run:cmd("start server replica with args='disable_replication'")
test_run:cmd("switch replica")
box.space.test:count() -- 99
test_run:cmd("switch default")
old_files = box.space.mem:get('files')[2]
new_files = test_run:eval("replica", "fio = require('fio') return fio.glob(fio.pathjoin(box.cfg.vinyl_dir, box.space.test.id, 0, '*'))")[1]
#old_files == #new_files
test_run:cmd("stop server replica")
box.error.injection.set('ERRINJ_RELAY_FINAL_JOIN', false)

-- Rebootstrap after several failed attempts and make sure
-- old files are removed.
test_run:cmd("start server replica")
test_run:cmd("switch replica")
box.cfg{checkpoint_count = 1}
box.snapshot()
box.space.test:count() -- 98
test_run:cmd("switch default")
files = box.space.mem:get('files')[2]
ok = true
fio = require('fio')
for _, f in ipairs(files) do ok = ok and not fio.path.exists(f) end
ok
test_run:cmd("stop server replica")

-- Cleanup.
test_run:cmd("cleanup server replica")
box.space.test:drop()
box.space.mem:drop()
box.schema.user.revoke('guest', 'replication')
