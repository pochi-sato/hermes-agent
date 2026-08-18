"""Tests for ``/branch --thread`` — fork a session into a NEW platform thread.

Design under test (docs/pochinin-fork-thread-bind-review.md): the gateway
creates a platform thread via the adapter's optional ``create_session_thread``
capability, copies the conversation into a forked session whose routing
columns point at THAT thread, and pre-binds the thread's session key —
leaving the CURRENT chat's session completely untouched.

The load-bearing invariants:

1. The fork row's ``session_key`` byte-matches what a REAL inbound message
   from the new thread derives (Discord: chat_id == thread_id == the thread's
   channel id, chat_type "thread"). A mismatch makes the fork permanently
   unroutable.
2. A store that lost its routing index (process restart) still resolves the
   new thread to the fork via find_latest_gateway_session_for_peer — the
   routing columns land in the SAME write as the row (#82633 pattern).
3. The parent session is not ended, not switched, and messages appended to
   it after the fork do not leak into the fork.

Same conventions as test_branch_routing_columns.py: REAL SessionStore +
REAL SessionDB (SQLite in tmp_path), minimal GatewayRunner stub, fake
adapter only at the platform boundary.
"""

from __future__ import annotations

import json

import pytest

from gateway.config import GatewayConfig, Platform
from gateway.platforms.base import MessageEvent
from gateway.session import SessionSource, SessionStore
from hermes_state import AsyncSessionDB


NEW_THREAD_ID = "999000999"
PARENT_CHANNEL_ID = "555000555"


@pytest.fixture()
def store(tmp_path, monkeypatch):
    """Real SessionStore backed by a real SessionDB (SQLite in tmp_path)."""
    import hermes_state

    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", tmp_path / "state.db")
    config = GatewayConfig()
    return SessionStore(sessions_dir=tmp_path / "sessions", config=config)


class FakeThreadAdapter:
    """Discord-shaped adapter exposing only the capability under test."""

    def __init__(self, fail_with: str | None = None):
        self.fail_with = fail_with
        self.created: list[dict] = []
        self.sent: list[tuple[str, str]] = []

    async def create_session_thread(
        self,
        *,
        chat_id,
        thread_id=None,
        name,
        requested_by="",
        auto_archive_duration=1440,
    ):
        self.created.append(
            {"chat_id": chat_id, "thread_id": thread_id, "name": name}
        )
        if self.fail_with:
            return {"error": self.fail_with}
        return {
            "success": True,
            "thread_id": NEW_THREAD_ID,
            "thread_name": name,
            "parent_channel_id": PARENT_CHANNEL_ID,
        }

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((chat_id, content))
        return None


def _make_source() -> SessionSource:
    # A message arriving from INSIDE an existing Discord thread:
    # chat_id == thread_id == the thread's channel id (adapter convention,
    # plugins/platforms/discord/adapter.py _thread_id_and_chat_for_channel).
    return SessionSource(
        platform=Platform.DISCORD,
        chat_id="777000111",
        chat_type="thread",
        thread_id="777000111",
        user_id="42",
        user_name="takuto",
        chat_name="guild / original-thread",
    )


def _inbound_source_from_new_thread(user_id: str = "42") -> SessionSource:
    """What a REAL follow-up message in the newly created thread carries."""
    return SessionSource(
        platform=Platform.DISCORD,
        chat_id=NEW_THREAD_ID,
        chat_type="thread",
        thread_id=NEW_THREAD_ID,
        user_id=user_id,
        chat_name="guild / forked-thread",
    )


def _make_event(text: str) -> MessageEvent:
    return MessageEvent(text=text, source=_make_source(), message_id="m1")


def _make_runner(store: SessionStore, adapter=None):
    from gateway.run import GatewayRunner

    runner = object.__new__(GatewayRunner)
    runner.adapters = {Platform.DISCORD: adapter} if adapter is not None else {}
    runner.config = {}
    runner._background_tasks = set()
    runner._running_agents = {}
    runner._running_agents_ts = {}
    runner._busy_ack_ts = {}
    runner._pending_approvals = {}
    runner._update_prompt_pending = {}
    runner._agent_cache_lock = None
    runner.session_store = store
    runner._session_db = AsyncSessionDB(store._db)
    runner._pending_skills_reload_notes = {}
    return runner


def _seed_parent(store: SessionStore):
    """Create the current-thread session with a short conversation."""
    source = _make_source()
    parent_entry = store.get_or_create_session(source)
    store._db.append_message(
        parent_entry.session_id, role="user", content="hello",
        api_content=json.dumps({"role": "user", "content": "hello-wire"}),
    )
    store._db.append_message(
        parent_entry.session_id, role="assistant", content="world"
    )
    return source, parent_entry


class TestBranchThreadBind:
    @pytest.mark.asyncio
    async def test_fork_key_matches_real_inbound_source(self, store):
        """Invariant #1: the fork row's session_key equals the key a real
        inbound message from the new thread derives. Hand-formatted keys or
        wrong chat_id/thread_id conventions break routing forever."""
        _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)

        await runner._handle_branch_command(_make_event("/branch --thread case-b"))

        expected_key = store._generate_session_key(_inbound_source_from_new_thread())
        row = store._db.find_latest_gateway_session_for_peer(
            source="discord", session_key=expected_key
        )
        assert row is not None, (
            "no session row matches the key a real inbound thread message "
            "derives — the fork is unroutable"
        )
        assert row["chat_id"] == NEW_THREAD_ID
        assert row["thread_id"] == NEW_THREAD_ID
        assert row["chat_type"] == "thread"
        assert row["user_id"] == "42"
        assert row["origin_json"], "origin_json missing on the fork row"
        origin = json.loads(row["origin_json"])
        assert origin.get("chat_id") == NEW_THREAD_ID
        assert origin.get("thread_id") == NEW_THREAD_ID

    @pytest.mark.asyncio
    async def test_fork_bound_in_memory_and_parent_untouched(self, store):
        """Invariant #3: current chat keeps its session; new thread's key is
        pre-bound to the fork; parent row is not ended."""
        source, parent_entry = _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)

        await runner._handle_branch_command(_make_event("/branch --thread"))

        # Parent untouched: same entry, row still open.
        parent_key = store._generate_session_key(source)
        assert store.peek_session_id(parent_key) == parent_entry.session_id
        parent_row = store._db.get_session(parent_entry.session_id)
        assert parent_row["ended_at"] is None, (
            "parent session was ended — /branch --thread must not touch the "
            "current chat (the API fork's end('branched') is the wrong model)"
        )

        # New thread's key resolves to the fork without any inbound message.
        inbound = _inbound_source_from_new_thread()
        fork_entry = store.get_or_create_session(inbound)
        assert fork_entry.session_id != parent_entry.session_id
        fork_row = store._db.get_session(fork_entry.session_id)
        assert fork_row["parent_session_id"] == parent_entry.session_id

    @pytest.mark.asyncio
    async def test_fork_recovered_after_restart(self, store, tmp_path):
        """Invariant #2: a fresh store with NO routing index (simulated
        restart / lost sessions.json) still resolves the new thread to the
        fork purely from the row's routing columns."""
        source, parent_entry = _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)
        await runner._handle_branch_command(_make_event("/branch --thread resume-me"))

        fresh = SessionStore(
            sessions_dir=tmp_path / "sessions-after-restart",
            config=GatewayConfig(),
        )
        try:
            entry = fresh.get_or_create_session(_inbound_source_from_new_thread())
            row = fresh._db.get_session(entry.session_id)
            assert row["parent_session_id"] == parent_entry.session_id, (
                "restart recovery minted a fresh session instead of the fork"
            )
            transcript = fresh.load_transcript(entry.session_id)
            assert [m["role"] for m in transcript] == ["user", "assistant"]
        finally:
            fresh._db.close()

    @pytest.mark.asyncio
    async def test_fork_copies_api_content_sidecar_and_marker(self, store):
        """Prompt-cache + independence plumbing: api_content survives the
        copy, and the _branched_from marker is on the fork row (it keeps the
        fork out of the parent's lineage reads and listable without ending
        the parent)."""
        source, parent_entry = _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)
        await runner._handle_branch_command(_make_event("/branch --thread cache"))

        fork_entry = store.get_or_create_session(_inbound_source_from_new_thread())
        fork_row = store._db.get_session(fork_entry.session_id)
        model_config = json.loads(fork_row["model_config"] or "{}")
        assert model_config.get("_branched_from") == parent_entry.session_id

        msgs = store._db.get_messages(fork_entry.session_id)
        user_rows = [m for m in msgs if m.get("role") == "user"]
        assert user_rows, "fork transcript lost its user rows"
        assert any(m.get("api_content") for m in user_rows), (
            "api_content sidecar dropped in the copy — the fork's first turn "
            "pays a cold prefill instead of replaying the parent's wire bytes"
        )

    @pytest.mark.asyncio
    async def test_post_fork_parent_messages_do_not_leak(self, store):
        """Source/fork independence: messages appended to the parent AFTER
        the fork must not appear in the fork's transcript."""
        source, parent_entry = _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)
        await runner._handle_branch_command(_make_event("/branch --thread leak"))

        store._db.append_message(
            parent_entry.session_id, role="user", content="post-fork parent msg"
        )

        fork_entry = store.get_or_create_session(_inbound_source_from_new_thread())
        transcript = store.load_transcript(fork_entry.session_id)
        contents = [m.get("content") for m in transcript]
        assert "post-fork parent msg" not in contents

    @pytest.mark.asyncio
    async def test_unsupported_platform_no_side_effects(self, store):
        """An adapter without the capability yields a clean error and leaves
        no fork row keyed to any thread."""
        _seed_parent(store)

        class NoCapabilityAdapter:
            pass

        runner = _make_runner(store, NoCapabilityAdapter())

        reply = await runner._handle_branch_command(_make_event("/branch --thread x"))

        expected_key = store._generate_session_key(_inbound_source_from_new_thread())
        assert store._db.find_latest_gateway_session_for_peer(
            source="discord", session_key=expected_key
        ) is None, "a fork row was created despite no capability"
        assert isinstance(reply, str) and reply

    @pytest.mark.asyncio
    async def test_thread_create_failure_creates_no_row(self, store):
        """Ordering: thread creation happens BEFORE the row, so a platform
        failure leaves zero session-side effects — the new thread's key must
        resolve to nothing, and a later message there starts fresh (no
        orphaned fork parentage)."""
        _seed_parent(store)
        adapter = FakeThreadAdapter(fail_with="missing permissions")
        runner = _make_runner(store, adapter)

        reply = await runner._handle_branch_command(_make_event("/branch --thread x"))

        assert adapter.created, "capability was never invoked"
        assert isinstance(reply, str) and reply
        expected_key = store._generate_session_key(_inbound_source_from_new_thread())
        assert store._db.find_latest_gateway_session_for_peer(
            source="discord", session_key=expected_key
        ) is None, "row created even though the thread was not"
        entry = store.get_or_create_session(_inbound_source_from_new_thread())
        row = store._db.get_session(entry.session_id)
        assert row["parent_session_id"] is None, (
            "a failed thread creation still produced fork parentage"
        )

    @pytest.mark.asyncio
    async def test_intro_sent_into_new_thread(self, store):
        """The confirmation lands in the current chat (returned string); the
        intro is sent into the NEW thread."""
        _seed_parent(store)
        adapter = FakeThreadAdapter()
        runner = _make_runner(store, adapter)

        reply = await runner._handle_branch_command(_make_event("/branch --thread hi"))

        assert adapter.sent and adapter.sent[0][0] == NEW_THREAD_ID
        assert NEW_THREAD_ID in reply or "hi" in reply

    def test_bind_session_key_collision_guard(self, store):
        """bind_session_key never steals an occupied routing key, and is
        idempotent on the same target."""
        source = _make_source()
        entry = store.get_or_create_session(source)
        key = store._generate_session_key(source)

        # Same target → idempotent success.
        again = store.bind_session_key(key, entry.session_id, origin=source)
        assert again is not None and again.session_id == entry.session_id

        # Different target → refused.
        stolen = store.bind_session_key(key, "some_other_session", origin=source)
        assert stolen is None
