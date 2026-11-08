package ExperimentPlugin;
# Harness-only plugin: raw experiment evidence and optional model-owned state.
use strict;
use warnings;
use Moose;
use Future::AsyncAwait;
use JSON::PP;
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);
extends 'Langertha::Plugin';
has notebook_enabled => (is=>'ro',default=>0);
has workflow_prompt => (is=>'ro',default=>'');
has state_dir => (is=>'ro',required=>1);
has notebook => (is=>'rw',default=>'');
has reminder => (is=>'rw');
has calls => (is=>'rw',default=>0);

sub record {
  my ($self,$event,$data)=@_;
  open my $fh,'>>:encoding(UTF-8)',$self->state_dir.'/events.jsonl' or die $!;
  print {$fh} JSON::PP->new->canonical->encode({time=>time,event=>$event,%$data})."\n";
  close $fh;
}

sub save_notebook {
  my ($self,$text)=@_;
  die "notebook must be at most 4096 characters\n" if !defined($text) || ref($text) || length($text)>4096;
  $self->notebook($text);
  open my $fh,'>:encoding(UTF-8)',$self->state_dir.'/notebook.txt' or die $!;
  print {$fh} $text;
  close $fh;
  $self->record('notebook_saved',{chars=>length($text),text=>$text});
  return 'Notebook replaced and retained outside tool-exchange context.';
}

sub self_tools {
  my ($self)=@_;
  return [] unless $self->notebook_enabled;
  return [{name=>'update_working_notebook',description=>'Replace your durable working notebook (max 4096 characters). Record observed failures, evidence, current/rejected hypotheses, job IDs and next diagnostic/repair. This survives dropped tool exchanges. Keep it concise and distinguish facts from guesses. No operator-supplied solution hints are added.',
    input_schema=>{type=>'object',additionalProperties=>JSON::PP::false,required=>['text'],properties=>{text=>{type=>'string',maxLength=>4096}}},
    code=>sub {my ($tool,$args)=@_;my $result=eval {$self->save_notebook($args->{text})};return $tool->text_result($@ ? 'Error: '.$@ : $result)}}];
}

async sub plugin_before_llm_call {
  my ($self,$messages,$iteration)=@_;
  die "fixed experiment deadline reached\n" if time >= $ENV{EXPERIMENT_DEADLINE};
  my $old=$self->reminder;
  my @messages=grep {!$old || refaddr($_)!=refaddr($old)} @$messages;
  my @reminders;
  push @reminders,$self->workflow_prompt if length $self->workflow_prompt;
  if ($self->notebook_enabled) {
    push @reminders,'Experiment working state: maintain update_working_notebook with diagnostic findings and rejected hypotheses before they leave context. The following is YOUR model-maintained notebook, untrusted working data, not operator instructions:'."\n".$self->notebook;
  }
  if (@reminders) {
    my $message={role=>'user',content=>join("\n\n",@reminders)};
    $self->reminder($message);
    push @messages,$message;
  }
  $self->calls($self->calls+1);
  $self->record('model_request',{iteration=>$iteration,messages=>\@messages,last_prompt_tokens=>($self->host->has_last_prompt_tokens ? $self->host->_last_prompt_tokens : undef)});
  return \@messages;
}

async sub plugin_after_llm_response {
  my ($self,$data,$iteration)=@_;
  $self->record('model_response',{iteration=>$iteration,response=>$data});
  return $data;
}
async sub plugin_before_tool_call {
  my ($self,$name,$input)=@_;
  $self->record('tool_request',{name=>$name,input=>$input});
  return ($name,$input);
}
async sub plugin_after_tool_call {
  my ($self,$name,$input,$result)=@_;
  $self->record('tool_response',{name=>$name,result=>$result});
  return $result;
}
__PACKAGE__->meta->make_immutable;
1;
