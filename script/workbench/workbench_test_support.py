"""Shared test helper for broker request envelopes. Not a test_*.py module."""


def envelope(action, scope, channel='#ai', network='irc.perl.org', requester='mateu'):
    return {'action': action, 'scope': scope, 'requester': requester,
            'channel': channel, 'network': network}
