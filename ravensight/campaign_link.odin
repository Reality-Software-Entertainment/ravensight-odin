// campaign_link.odin - set_campaign_link, for a player who arrived by a
// Ravensight campaign link.

package ravensight

@(private)
campaign_link_id :: proc(text: string, buf: ^[24]u8) -> (string, bool) {
	return "", false
}

set_campaign_link :: proc(client: ^Client, link_id: string) -> bool {
	return false
}
