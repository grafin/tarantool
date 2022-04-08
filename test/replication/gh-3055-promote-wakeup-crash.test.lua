test_run = require('test_run').new()
--
-- gh-3055 follow-up: box.ctl.promote() could crash on an assertion after a
-- spurious wakeup.
--
_ = box.space._cluster:insert{2,\
                              require('uuid').str(),\
                              require('datetime').now(),\
                              box.info.uuid,\
                              require('datetime').new(),\
                              require('uuid').NULL:str()}
box.cfg{election_mode='manual',\
        replication_synchro_quorum=2,\
        election_timeout=1000}

fiber = require('fiber')
f = fiber.create(function() box.ctl.promote() end)
f:set_joinable(true)
f:wakeup()
fiber.yield()

-- Cleanup.
f:cancel()
f:join()
box.cfg{election_mode='off'}
test_run:cleanup_cluster()
