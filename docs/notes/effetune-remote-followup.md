# EffeTune remote control follow-up

Upstream [PR #69](https://github.com/Frieve-A/effetune/pull/69), “Add a LAN remote control API with a browser client”, was merged on 2026-10-04. The latest application release at that point is v2.12.0, which predates the merge.

Release the current EffectDeck main independently. Adopt the upstream remote control when an EffeTune release containing PR #69 becomes available.

For that integration, compare the released server protocol with EffectDeck's existing remote client, including hello/version negotiation, effect availability, authentication and connection handling. Update the pinned upstream release and generated DSP/catalog data as needed, then verify remote operation against the released desktop EffeTune before shipping EffectDeck support.
