create type run_state as enum (
  'created', 'running', 'awaiting_effects', 'waiting',
  'completed', 'failed', 'timed_out', 'cancelled'
);

-- Automation: the instruction. Versioned; runs pin the version they started on.
create table automation (
  id            uuid primary key,
  account_id    text not null,          
  name          text not null,
  enabled       boolean not null default true,
  created_at    timestamptz not null default now()
);

create table automation_version (
  automation_id uuid not null references automation(id),
  version       integer not null,
  trigger       jsonb not null,         
  steps         jsonb not null,         
  duplicate_commenter_policy text not null default 'one_active_run',
                                        -- 'ignore' | 'restart' | 'one_active_run'
  created_at    timestamptz not null default now(),
  primary key (automation_id, version)
);

-- Run: one execution of an automation for one triggering comment.
create table run (
  id                uuid primary key,
  automation_id     uuid not null,
  automation_version integer not null,
  person_id         text not null,      -- handle of the commenter
  comment_id        text not null,      -- handle of the triggering comment
  state             run_state not null default 'created',
  step_index        integer not null default 0,
  variables         jsonb not null default '{}'::jsonb,   -- what steps captured
  step_results      jsonb not null default '[]'::jsonb,   -- history, one entry per executed step
  pending_messages  jsonb not null default '[]'::jsonb,   -- messages from the user that arrived
                                                          -- before a wait step
  attempts          integer not null default 0,           -- retries of the current step
  failure_reason    text,
  version           integer not null default 0,           
  lease_owner       text,
  lease_until       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  finished_at       timestamptz,
  foreign key (automation_id, automation_version)
    references automation_version(automation_id, version)
);

-- at most one active run per
-- person per automation.
create unique index run_one_active_per_user
  on run (automation_id, person_id)
  where state in ('created', 'running', 'awaiting_effects', 'waiting');

-- The inbound DM path finds the active run for a person; the account is
-- matched by joining automation (no copied account column on run).
create index run_active_by_person
  on run (person_id)
  where state in ('created', 'running', 'awaiting_effects', 'waiting');

-- Wait subscription: the bookmark from a waiting run to the user it waits for.
-- Registered by the wait step. Messages that arrive earlier are kept on
-- run.pending_messages (README section 6, item 2).
create table wait_subscription (
  run_id            uuid primary key references run(id),
  person_id         text not null,
  step_index        integer not null,
  deadline          timestamptz not null,
  reprompts_sent    integer not null default 0,
  claimed_by_event  text,                -- set by the atomic first-wins claim
  created_at        timestamptz not null default now()
);

-- The inbound DM path looks up by who sent the message, then joins run and
-- automation to match the account.
create index wait_subscription_by_person
  on wait_subscription (person_id);

-- The sweeper looks up by deadline.
create index wait_subscription_by_deadline
  on wait_subscription (deadline);

-- Contact: one person per account reached through automations, with what
-- was captured about them. Upserted by the local effect save_contact
-- (README section 3, "Contact"; section 5, local vs external effects).
create table contact (
  id                uuid primary key,
  account_id        text not null,      -- owner: the contact list is per connected account
  person_id         text not null,
  email             text,
  fields            jsonb not null default '{}'::jsonb,   -- other captured values
  first_run_id      uuid references run(id),
  last_run_id       uuid references run(id),
  captured_at       timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (account_id, person_id)
);

create index contact_by_account_email
  on contact (account_id, email);

-- Queue: work waiting for a worker. Claimed with
--   select ... where status = 'queued' and run_after <= now()
--   order by run_after for update skip locked limit N
create table queue (
  id            bigserial primary key,
  kind          text not null,           -- 'match_comment' | 'advance_run'
                                         -- | 'effect_done' | 'effect_failed'
  payload       jsonb not null,          -- the comment, or {run_id, event}
  status        text not null default 'queued',   -- 'queued' | 'claimed' | 'done'
  run_after     timestamptz not null default now(),
  attempts      integer not null default 0,
  lease_owner   text,
  lease_until   timestamptz,
  created_at    timestamptz not null default now()
);

create index queue_claimable
  on queue (run_after)
  where status = 'queued';

-- Outbox: effects decided by the executor, not yet performed. The
-- idempotency key (run_id, step_index, seq) lives here. When the sender marks
-- a row 'sent' or 'failed' it enqueues effect_done / effect_failed for the run
-- in the same transaction, which is what lets the run advance (README 5).
create table outbox (
  id            bigserial primary key,
  run_id        uuid not null references run(id),
  step_index    integer not null,
  seq           integer not null default 0,   -- a step may emit more than one effect
  effect        jsonb not null,               -- {type: 'send_dm', person_id, text} or
                                              -- {type: 'reply_comment', comment_id, text};
                                              -- the adapter resolves the sending account
  status        text not null default 'pending',  -- 'pending' | 'sent' | 'failed'
  attempts      integer not null default 0,
  run_after     timestamptz not null default now(),
  sent_at       timestamptz,
  last_error    text,
  created_at    timestamptz not null default now(),
  unique (run_id, step_index, seq)
);

create index outbox_sendable
  on outbox (run_after)
  where status = 'pending';

-- Extension point (assumption 1, README section 8): inbound deduplication.
-- create table inbound_event (
--   event_id          text primary key,  -- opaque delivery handle from the integration layer
--   kind              text not null,     -- 'comment' | 'message'
--   payload           jsonb not null,
--   received_at       timestamptz not null default now()
-- );
-- Insert first; a conflict means a duplicate delivery, and the event is ignored.
