// identify.odin - identify and reset_identity, for a game with its own
// sign-in.
//
// identify(client, account_id) links this device to the game's own account.
// Only a salted hash of the id leaves the device:
//
//   accountHash = lowercase hex HMAC-SHA256(key = the salt string from the
//                 session answer's identify.salt, message = account_id)
//
// sent once per session to POST /api/v1/identify with the key and the
// session token. The account id is held in memory until the salt is known and
// is never written anywhere; the storage file keeps only
// "identity":{"salt":...,"accountHash":...}.

package ravensight

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

// The longest account id accepted, in UTF-8 bytes.
IDENTIFY_MAX_BYTES :: 256

// The refusal code for an account id, or "" when it may be used: "empty",
// "too_long" (over 256 UTF-8 bytes) or "looks_like_email" (any '@'). The id
// is checked exactly as given, never trimmed.
identify_refusal :: proc(account_id: string) -> string {
	if len(account_id) == 0 {
		return "empty"
	}
	if len(account_id) > IDENTIFY_MAX_BYTES {
		return "too_long"
	}
	if strings.contains_rune(account_id, '@') {
		return "looks_like_email"
	}
	return ""
}

// Lower case hex HMAC-SHA256 keyed with the UTF-8 bytes of the salt string
// exactly as the session answer gave it (not hex decoded), over the bytes of
// the account id.
identify_account_hash :: proc(account_id: string, salt: string, allocator := context.allocator) -> string {
	digest: [32]u8
	hmac.sum(hash.Algorithm.SHA256, digest[:], transmute([]u8)account_id, transmute([]u8)salt)
	return string(hex.encode(digest[:], allocator))
}

// Links this device to the game's own account. Call it after the player
// signs in. Returns false, with one warning, for an id that is empty, over
// 256 UTF-8 bytes or contains '@'; a refusal sends nothing and changes
// nothing. The same account again does nothing; a different account runs
// reset_identity first. Without a key, or with Consent.Opt_In before the
// player's yes, the id is held in memory only. A playtest run never stores
// or sends an identity.
identify :: proc(client: ^Client, account_id: string) -> bool {
	if client == nil {
		return false
	}
	context.allocator = client.allocator
	if reason := identify_refusal(account_id); reason != "" {
		log(client, .Warning, fmt.tprintf("Ravensight: identify refused (%s): pass an opaque account id, 1 to 256 bytes, with no @. Nothing was sent or changed.", reason))
		return false
	}
	if len(client.playtest.token) > 0 {
		return true
	}
	if identify_is_same(client, account_id) {
		return true
	}
	if is_identified(client) {
		reset_identity(client)
	}
	if client.launch_salt_missing {
		log(client, .Info, "Ravensight: identify is not offered by this server; nothing is kept this launch.")
		return true
	}
	if identify_can_store(client) && len(client.launch_salt) > 0 {
		identify_store(client, identify_account_hash(account_id, client.launch_salt, context.temp_allocator))
	} else {
		delete(client.identity_held)
		client.identity_held = strings.clone(account_id)
	}
	identify_if_due(client, want_session = true)
	return true
}

// For sign-out: forgets the stored identity (and any id held in memory) and
// switches to a fresh device id exactly as reset_device_id does, so the next
// session is not linked to the account. Does nothing when no identity is
// stored or held. Sends nothing.
reset_identity :: proc(client: ^Client) {
	if client == nil {
		return
	}
	context.allocator = client.allocator
	if !identify_forget(client, save = true) {
		return
	}
	reset_device_id(client)
}

// True while an identity is stored, or a valid id is held in memory.
is_identified :: proc(client: ^Client) -> bool {
	if client == nil {
		return false
	}
	return len(client.identity_hash) > 0 || len(client.identity_held) > 0
}

@(private)
identify_is_same :: proc(client: ^Client, account_id: string) -> bool {
	if len(client.identity_held) > 0 && client.identity_held == account_id {
		return true
	}
	if len(client.identity_hash) > 0 {
		return identify_account_hash(account_id, client.identity_salt, context.temp_allocator) == client.identity_hash
	}
	return false
}

@(private)
identify_can_store :: proc(client: ^Client) -> bool {
	return !client.core.inert && len(client.playtest.token) == 0 && !client.core.opted_out && len(client.storage_path) > 0
}

// Stores { salt, accountHash } for the launch's salt and saves the file.
@(private)
identify_store :: proc(client: ^Client, account_hash: string) {
	delete(client.identity_salt)
	delete(client.identity_hash)
	client.identity_salt = strings.clone(client.launch_salt)
	client.identity_hash = strings.clone(account_hash)
	identify_save(client)
}

@(private)
identify_save :: proc(client: ^Client) {
	if client.core.inert || len(client.storage_path) == 0 {
		return
	}
	saved := Saved_Identity{
		device_id        = client.saved_device_id,
		tracking_enabled = !client.core.opted_out,
		opted_in         = client.saved_opt_in,
		identity_salt    = client.identity_salt,
		identity_hash    = client.identity_hash,
	}
	if !save_identity(client.storage_path, saved) {
		log(client, .Warning, "Ravensight: could not save the identity to the storage file.")
	}
}

// Drops the stored identity and any held id. Returns whether there was one.
// `save` writes the file now; a caller about to write it itself passes false.
@(private)
identify_forget :: proc(client: ^Client, save: bool) -> bool {
	had := is_identified(client)
	if len(client.identity_hash) > 0 {
		delete(client.identity_salt)
		delete(client.identity_hash)
		client.identity_salt = ""
		client.identity_hash = ""
		if save {
			identify_save(client)
		}
	}
	delete(client.identity_held)
	client.identity_held = ""
	delete(client.identified_session)
	client.identified_session = ""
	client.identify_generation += 1
	return had
}

// A session answer arrived: learn the salt, and drop what it rules out.
@(private)
identify_session_answer :: proc(client: ^Client, obj: json.Object) {
	salt := ""
	if id, has := obj["identify"].(json.Object); has {
		if s, is_str := id["salt"].(json.String); is_str {
			salt = string(s)
		}
	}
	if len(salt) == 0 {
		// An older server: unavailable this launch, the held id dropped.
		client.launch_salt_missing = true
		delete(client.identity_held)
		client.identity_held = ""
		return
	}
	delete(client.launch_salt)
	client.launch_salt = strings.clone(salt)
	if len(client.identity_hash) > 0 && client.identity_salt != salt {
		// Made under another game's salt: deleted, never sent.
		delete(client.identity_salt)
		delete(client.identity_hash)
		client.identity_salt = ""
		client.identity_hash = ""
		identify_save(client)
	}
}

// Hashes a held id once it may be, and sends the identity once for the
// current session (or asks for a session when `want_session`). Never touches
// the event queue.
@(private)
identify_if_due :: proc(client: ^Client, want_session: bool) {
	if client.core.inert || len(client.playtest.token) > 0 || !core_is_active(&client.core) {
		return
	}
	if client.launch_salt_missing && len(client.identity_held) > 0 {
		delete(client.identity_held)
		client.identity_held = ""
	}
	if len(client.identity_held) > 0 && len(client.launch_salt) > 0 && identify_can_store(client) {
		identify_store(client, identify_account_hash(client.identity_held, client.launch_salt, context.temp_allocator))
		delete(client.identity_held)
		client.identity_held = ""
	}
	if client.identify_stopped || client.launch_salt_missing || !is_identified(client) {
		return
	}
	if !core_is_session_valid(&client.core, client_now(client)) || len(client.launch_salt) == 0 || len(client.identity_hash) == 0 {
		if want_session {
			core_want_session(&client.core)
		}
		return
	}
	token := client.core.session_token
	if client.identified_session == token {
		return
	}
	// Remembered before the answer: whatever it says, not again this session.
	delete(client.identified_session)
	client.identified_session = strings.clone(token)
	body := fmt.tprintf(`{{"accountHash":"%s"}}`, client.identity_hash)
	key := fmt.tprintf("X-API-Key: %s", client.ingest_key)
	t := start_request(client, "/identify", body, .Session_Token, []string{key})
	if t == nil {
		log(client, .Info, "Ravensight: identify could not start; it is tried again next session.")
		return
	}
	t.is_side = true
	t.side = .Identify
	t.identify_generation = client.identify_generation
	append(&client.side, t)
}

@(private)
identify_response :: proc(client: ^Client, t: ^Transfer, status: int, code: string) {
	if t.identify_generation != client.identify_generation {
		log(client, .Info, "Ravensight: ignored an identify answer that no longer applies.")
		return
	}
	switch {
	case status >= 200 && status < 300:
		log(client, .Info, "Ravensight: identified this session.")
	case status == 404:
		client.identify_stopped = true
		log(client, .Info, "Ravensight: identify is not offered by this server; not sent again this launch.")
	case status == 400 && code == "invalid_account_hash":
		client.identify_stopped = true
		if !client.warned_identify {
			client.warned_identify = true
			log(client, .Warning, "Ravensight: identify was refused as invalid_account_hash; not sent again this launch.")
		}
	case:
		log(client, .Info, fmt.tprintf("Ravensight: identify not accepted (%s), tried again next session.", len(code) > 0 ? code : "offline"))
	}
}
