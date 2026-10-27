package Bot::Runtime::RaiderPlugin::CodingTask;
use strict;
use warnings;
use Moose;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use Bot::Runtime::Limits qw(now);
extends 'Langertha::Plugin';

has pending => (is=>'ro', isa=>'CodeRef', required=>1);
has reminder => (is=>'rw');

async sub plugin_before_llm_call {
  my ($self,$messages,$iteration)=@_;
  my $old=$self->reminder;
  my @messages=grep { !$old || refaddr($_) != refaddr($old) } @$messages;
  my $p=$self->pending->();
  unless ($p && $p->{coding_task}) {
    $self->reminder(undef);
    return \@messages;
  }
  $p->{coding_stop_reason}='coding deadline reached' if now() >= $p->{expires_at};
  $p->{coding_stop_reason}='sandbox attempt budget exhausted before a complete project passed'
    if defined($p->{coding_attempts_remaining}) && $p->{coding_attempts_remaining} == 0
      && ($p->{coding_last_repo_state}//'') eq 'failed';
  die "Coding task stopped: $p->{coding_stop_reason}\n" if $p->{coding_stop_reason};
  my $text='Runtime coding budget: FIVE sandbox runs total, including diagnostics. '
    .'Read test failures and repair only the affected files with repair_repo_project; unchanged files are preserved. '
    .'For diagnostics use diagnose_repo_job with that saved id and a diagnostic argv, NEVER copy project files into run_code. '
    .'Use inspect_repo_job if source was lost from context. Never restart the project or weaken tests to get a pass. '
    .'Only a passed complete-project repository job can be published; return the actual commit URL. '
    .'If blocked, report exact failures and unfinished work.';
  $text.=" Remaining sandbox runs: $p->{coding_attempts_remaining}." if defined $p->{coding_attempts_remaining};
  $text.=" Latest repository job: $p->{coding_last_repo_job} ($p->{coding_last_repo_state})." if $p->{coding_last_repo_job};
  my $message={role=>'system',content=>$text};
  $self->reminder($message);
  push @messages,$message;
  return \@messages;
}

__PACKAGE__->meta->make_immutable;
1;
