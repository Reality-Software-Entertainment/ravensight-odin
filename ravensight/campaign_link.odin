// campaign_link.odin - set_campaign_link, for a player who arrived by a
// Ravensight campaign link.
//
// A campaign link adds rs_link=<link id> to the address of the page it
// redirects to. The game's own deep link, universal link, App Link or
// install referrer handler passes that id here. It goes once, lower cased,
// as campaignLink on the player's next POST /session (never in a playtest
// run), and is forgotten only when that session is answered 201 with a
// token. Memory only. This package has no web build, so it never reads a
// page address itself.

package ravensight

import "core:strings"

// The link id, lower cased into `buf`, when `text` is exactly 24 hex
// characters in any case. Never trims.
@(private)
campaign_link_id :: proc(text: string, buf: ^[24]u8) -> (string, bool) {
	if len(text) != len(buf) {
		return "", false
	}
	for i in 0 ..< len(text) {
		switch ch := text[i]; ch {
		case '0' ..= '9', 'a' ..= 'f':
			buf[i] = ch
		case 'A' ..= 'F':
			buf[i] = ch - 'A' + 'a'
		case:
			return "", false
		}
	}
	return string(buf[:]), true
}

// The Ravensight campaign link this player arrived by: the rs_link value
// (24 hex characters, any case) your deep link, universal link, App Link or
// install referrer handler pulled out of the incoming address. It goes once,
// as campaignLink, with the next session this client opens for the player,
// and is forgotten when the server accepts that session; a failed attempt
// keeps it for the next. Returns true when `link_id` is a link id and is now
// waiting; anything else returns false and leaves a waiting link as it was.
// A later valid call replaces it. Best called before the first session.
// Never sent in a playtest run, before consent or without a key, and never
// written to the storage file.
set_campaign_link :: proc(client: ^Client, link_id: string) -> bool {
	if client == nil {
		return false
	}
	buf: [24]u8
	link, ok := campaign_link_id(link_id, &buf)
	if !ok {
		log(client, .Info, "Ravensight: campaign link refused: a link id is 24 hex characters. Nothing changed.")
		return false
	}
	if link != client.campaign_link {
		delete(client.campaign_link, client.allocator)
		client.campaign_link = strings.clone(link, client.allocator)
	}
	return true
}

// Writes the waiting link into a session body, when this session may carry
// it, and remembers which link the request in flight carries.
@(private)
campaign_link_write :: proc(client: ^Client, b: ^strings.Builder) {
	client.campaign_link_in_flight = false
	if len(client.campaign_link) == 0 || len(client.playtest.token) > 0 {
		return
	}
	strings.write_string(b, `,"campaignLink":`)
	write_json_string(b, client.campaign_link)
	copy(client.campaign_link_sent[:], client.campaign_link)
	client.campaign_link_in_flight = true
}

// A session answer: a 201 with a token means the server has the link, so it
// is forgotten. A different link set while the request was in flight waits
// for the next session, and any other answer keeps it for the next attempt.
@(private)
campaign_link_answer :: proc(client: ^Client, status: int, token: string) {
	if status == 201 && len(token) > 0 && client.campaign_link_in_flight &&
	   client.campaign_link == string(client.campaign_link_sent[:]) {
		delete(client.campaign_link, client.allocator)
		client.campaign_link = ""
	}
	client.campaign_link_in_flight = false
}
