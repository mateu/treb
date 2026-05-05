use strict;
use warnings;
use Test::More;

local $ENV{DB_FILE} = 't/burt_non_substantive.sqlite';
unlink $ENV{DB_FILE} if -f $ENV{DB_FILE};
local $ENV{IRC_NICKNAME} = 'burt_bot';
local $ENV{BOT_IDENTITY_SLUG} = 'burt';

require './burt.pl';
my $bot = BurtBot->new();

ok($bot->_is_trivial_parenthetical('( ... )'), 'dot parenthetical is trivial');
ok($bot->_is_trivial_parenthetical('(…)'), 'unicode ellipsis parenthetical is trivial');
ok($bot->_is_trivial_parenthetical('(pause)'), 'pause parenthetical is trivial');
ok(!$bot->_is_trivial_parenthetical('(the chickens are in, by the way)'), 'real content parenthetical not trivial');
my @non_substantive_cases = (
  ['( ... )', 'trivial parenthetical is non-substantive'],
  ['(Silent - Treb\'s greeting is bot-to-bot banter, no human involved.)', 'silent policy narration is non-substantive'],
  ['(Silent - continuing bot-to-bot banter without human involvement.)', 'continued silent-policy narration is non-substantive'],
  ['(Silence from the attic.)', 'attic silence line is non-substantive'],
  ['(The attic holds its peace.)', 'attic peace line is non-substantive'],
  ['(quietly listens from the basement)', 'basement listening line is non-substantive'],
  ['(watchfully waiting in the rafters)', 'rafter waiting line is non-substantive'],
  ['(softly observing from the corner)', 'corner observing line is non-substantive'],
  ['(Empty response - staying silent.)', 'empty response staying silent artifact is non-substantive'],
  ['(Empty response: silent)', 'empty response silent artifact is non-substantive'],
  ['(empty response)', 'bare parenthesized empty response artifact is non-substantive'],
  ['Empty response', 'bare empty response artifact is non-substantive'],
  ['(No response - staying silent)', 'no response staying silent artifact is non-substantive'],
  ['(no response)', 'bare parenthesized no response artifact is non-substantive'],
  ['No response', 'bare no response artifact is non-substantive'],
  ['(no output)', 'parenthesized no-output artifact is non-substantive'],
  ['No output.', 'bare no-output artifact is non-substantive'],
  ['<success>Bot chose silence.</success>', 'success-wrapped silence artifact is non-substantive'],
  ['success: Bot chose silence.</success>', 'malformed success-prefixed silence artifact is non-substantive'],
  ['<output>No output.</output>', 'output-wrapped no-output artifact is non-substantive'],
  ['<response>Nothing to add.</response>', 'response-wrapped nothing-to-add artifact is non-substantive'],
  ['status: Remaining quiet.', 'status-prefixed remaining-quiet artifact is non-substantive'],
  ['Staying silent.', 'plain staying silent line is non-substantive'],
  ['Remaining quiet.', 'plain remaining quiet line is non-substantive'],
  ['Just observing.', 'plain observing line is non-substantive'],
  ['Listening.', 'plain listening line is non-substantive'],
);

for my $case (@non_substantive_cases) {
  my ($text, $label) = @$case;
  ok($bot->_is_non_substantive_output($text), $label);
}

my @substantive_cases = (
  ['mateu: the chickens are in ok.', 'substantive line not non-substantive'],
  ['Use cpanm.', 'brief actionable answer remains substantive'],
  ['No output file was generated because the command failed.', 'diagnostic no-output explanation remains substantive'],
  ['Set SILENT_MODE=1 before running the test.', 'technical silent-mode instruction remains substantive'],
  ['https://example.com/no-output', 'URL mentioning no-output remains substantive'],
  ['The result is quiet because the amp is muted.', 'explanatory quiet sentence remains substantive'],
);

for my $case (@substantive_cases) {
  my ($text, $label) = @$case;
  ok(!$bot->_is_non_substantive_output($text), $label);
}

done_testing;
