use nqp;

class REPL { ... }

do {
    my $more-code-sentinel = {};

    my sub sorted-set-insert(@values, $value) {
        my $low        = 0;
        my $high       = @values.end;
        my $insert_pos = 0;

        while $low <= $high {
            my $middle = floor($low + ($high - $low) / 2);

            my $middle_elem = @values[$middle];

            if $middle == @values.end {
                if $value eq $middle_elem {
                    return;
                } elsif $value lt $middle_elem {
                    $high = $middle - 1;
                } else {
                    $insert_pos = +@values;
                    last;
                }
            } else {
                my $middle_plus_one_elem = @values[$middle + 1];

                if $value eq $middle_elem || $value eq $middle_plus_one_elem {
                    return;
                } elsif $value lt $middle_elem {
                    $high = $middle - 1;
                } elsif $value gt $middle_plus_one_elem {
                    $low = $middle + 1;
                } else {
                    $insert_pos = $middle + 1;
                    last;
                }
            }
        }

        splice(@values, $insert_pos, 0, $value);
    }

    my sub mkpath(IO::Path $full-path) {
        my ( :$directory, *% ) := $full-path.parts;
        my @parts = $*SPEC.splitdir($directory);

        for [\~] @parts.map(* ~ '/') -> $path {
            mkdir $path;
            unless $path.IO ~~ :d {
                fail "Unable to mkpath '$full-path': $path is not a directory";
            }
        }
    }

    my role ReadlineBehavior[$WHO] {
        my &readline    = $WHO<&readline>;
        my &add_history = $WHO<&add_history>;

        method repl-read(Mu \prompt) {
            my $line = readline(prompt);

            if $line.defined {
                add_history($line);
            }

            $line;
        }
    }

    my role LinenoiseBehavior[$WHO] {
        my &linenoise                      = $WHO<&linenoise>;
        my &linenoiseHistoryAdd            = $WHO<&linenoiseHistoryAdd>;
        my &linenoiseSetCompletionCallback = $WHO<&linenoiseSetCompletionCallback>;
        my &linenoiseAddCompletion         = $WHO<&linenoiseAddCompletion>;
        my &linenoiseHistoryLoad           = $WHO<&linenoiseHistoryLoad>;
        my &linenoiseHistorySave           = $WHO<&linenoiseHistorySave>;

        method completions-for-line(Str $line, int $cursor-index) { ... }

        method history-file() returns Str { ... }

        method init-line-editor {
            linenoiseSetCompletionCallback(sub ($line, $c) {
                eager self.completions-for-line($line, $line.chars).map(&linenoiseAddCompletion.assuming($c));
            });
            linenoiseHistoryLoad($.history-file);
        }

        method teardown-line-editor {
            my $err = linenoiseHistorySave($.history-file);

            if $err {
                note "Couldn't save your history to $.history-file";
            }
        }

        method repl-read(Mu \prompt) {
            self.update-completions;
            my $line = linenoise(prompt);

            if $line.defined {
                linenoiseHistoryAdd($line);
            }

            $line;
        }
    }

    my role FallbackBehavior {
        method repl-read(Mu \prompt) {
            print prompt;
            get;
        }
    }

    my role Completions {
        has @!completions = CORE::.keys.flatmap({
            /^ "&"? $<word>=[\w* <.lower> \w*] $/ ?? ~$<word> !! []
        }).sort;

        method update-completions {
            my $context := self.compiler.context;

            return unless $context;

            my $pad := nqp::ctxlexpad($context);
            my $it := nqp::iterator($pad);

            while $it {
                my $e := nqp::shift($it);
                my $k := nqp::iterkey_s($e);
                my $m = $k ~~ /^ "&"? $<word>=[\w* <.lower> \w*] $/;
                if $m {
                    my $word = ~$m<word>;
                    sorted-set-insert(@!completions, $word);
                }
            }

            my $PACKAGE = self.compiler.eval('$?PACKAGE', :outer_ctx($context));

            for $PACKAGE.WHO.keys -> $k {
                sorted-set-insert(@!completions, $k);
            }
        }

        method extract-last-word(Str $line) {
            my $m = $line ~~ /^ $<prefix>=[.*?] <|w>$<last_word>=[\w*]$/;

            return ( ~$m<prefix>, ~$m<last_word> );
        }

        method completions-for-line(Str $line, int $cursor-index) {
            return @!completions unless $line;

            # ignore $cursor-index until we have a backend that provides it
            my ( $prefix, $word-at-cursor ) = self.extract-last-word($line);

            # XXX this could be more efficient if we had a smarter starting index
            gather for @!completions -> $word {
                if $word ~~ /^ "$word-at-cursor" / {
                    take $prefix ~ $word;
                }
            }
        }
    }

    # *** WARNING ***
    #
    # If you want to add new methods as hooks into Perl6::Compiler, you'll need to
    # add support for them to Perl6::Compiler itself.  See the readline and eval
    # methods both in this file and in Perl6::Compiler for guidance on how to do
    # that
    class REPL {
        also does Completions;

        has Mu $.compiler;
        has Bool $!multi-line-enabled;
        has IO::Path $!history-file;

        has $!save_ctx;

        sub do-mixin($self, Str $module-name, $behavior, Str :$fallback) {
            my Bool $problem = False;
            try {
                CATCH {
                    when X::CompUnit::UnsatisfiedDependency & { .specification ~~ /"$module-name"/ } {
                        # ignore it
                    }
                    default {
                        say "I ran into a problem while trying to set up $module-name: $_";
                        if $fallback {
                            say "Falling back to $fallback (if present)";
                        }
                        $problem = True;
                    }
                }

                my $module = do require ::($module-name);
                my $new-self = $self but $behavior.^parameterize($module.WHO<EXPORT>.WHO<ALL>.WHO);
                $new-self.?init-line-editor();
                return ( $new-self, False );
            }

            ( Any, $problem )
        }

        sub mixin-readline($self, |c) {
            do-mixin($self, 'Readline', ReadlineBehavior, |c)
        }

        sub mixin-linenoise($self, |c) {
            do-mixin($self, 'Linenoise', LinenoiseBehavior, |c)
        }

        sub mixin-line-editor($self) {
            my $new-self;
            my Bool $problem;

            my %editor-to-mixin = (
                :Linenoise(&mixin-linenoise),
                :Readline(&mixin-readline),
                :none(-> $self { ( $self but FallbackBehavior, False ) }),
            );

            if %*ENV<RAKUDO_LINE_EDITOR> -> $line-editor {
                if %editor-to-mixin{$line-editor} -> $mixin {
                    ( $new-self, $problem ) = $mixin($self);

                    if $new-self {
                        return $new-self;
                    } else {
                        unless $problem {
                            say "Could not find $line-editor module";
                        }
                        return $self but FallbackBehavior;
                    }
                } else {
                    say "Unrecognized line editor '$line-editor'";
                    return $self but FallbackBehavior;
                }
            } else {
                ( $new-self, $problem ) = mixin-readline($self, :fallback<Linenoise>);

                return $new-self if $new-self;

                ( $new-self, $problem ) = mixin-linenoise($self);

                return $new-self if $new-self;

                if $problem {
                    say 'Continuing without tab completions or line editor';
                    say 'You may want to consider using rlwrap for simple line editor functionality';
                } else {
                    say 'You may want to `panda install Readline` or `panda install Linenoise` or use rlwrap for a line editor';
                }
                say '';
            }

            $self but FallbackBehavior
        }

        method new(Mu \compiler, Mu \adverbs) {
            return if $*VM.name eq 'jvm';

            my $multi-line-enabled = !%*ENV<RAKUDO_DISABLE_MULTILINE>;
            my $self = self.bless();
            $self.init(compiler, $multi-line-enabled);
            $self = mixin-line-editor($self);

            $self
        }

        method init(Mu \compiler, $multi-line-enabled) {
            $!compiler = compiler;
            $!multi-line-enabled = $multi-line-enabled;
        }

        method teardown {
            self.?teardown-line-editor;
        }

        method partial-eval(Mu \code, Mu \adverbs) {
            my &needs_more_input = adverbs<needs_more_input>;

            CATCH {
                when X::Syntax::Missing {
                    if $!multi-line-enabled && .pos == code.chars {
                        return needs_more_input();
                    } else {
                        .throw;
                    }
                }

                when X::Comp::FailGoal {
                    if $!multi-line-enabled && .pos == code.chars {
                        return needs_more_input();
                    } else {
                        .throw;
                    }
                }

            }

            my $result := self.compiler.eval(code, |%(adverbs));

            return $result;
        }

        method repl-eval($code, *%adverbs) {
            my $needs_more_input = False;
            %adverbs<needs_more_input> := sub () {
                $needs_more_input = True;
            };
            my $result := self.partial-eval($code, %adverbs);
            if $needs_more_input {
                return $more-code-sentinel;
            }
            return $result;
        }

        method interactive_prompt() { '> ' }

        method repl-loop(*%adverbs) {

            my $prompt = self.interactive_prompt;
            my $code = "";

            REPL: loop {

                my $newcode = self.repl-read(~$prompt);

                # An undef $newcode implies ^D or similar
                if !$newcode.defined {
                    last;
                }

                $code = $code ~ $newcode ~ "\n";

                my $*CTXSAVE := self;
                my $*MAIN_CTX;

                my $output;
                {
                    $output := self.repl-eval(
                        $code,
                        :outer_ctx($!save_ctx),
                        |%adverbs);

                    CATCH {
                        say $_;
                        $code = '';
                        $prompt = self.interactive_prompt;
                        next REPL;
                    }
                };

                if self.input-incomplete($output) {
                    # Need to get more code before we execute
                    # Strip the trailing \, but reinstate the newline
                    if $code.substr(* - 2) eq "\\\n" {
                        $code = $code.substr(0, * - 2) ~ "\n";
                    }
                    if $code {
                        $prompt = '* ';
                    }
                    next;
                }

                if $*MAIN_CTX {
                    $!save_ctx := $*MAIN_CTX;
                }

                $code = "";
                $prompt = self.interactive_prompt;

                self.repl-print($output);
            }

            self.teardown();
        }

        # Inside of the EVAL it does like caller.ctxsave
        method ctxsave() {
            $*MAIN_CTX := nqp::ctxcaller(nqp::ctx());
            $*CTXSAVE := 0;
        }

        method input-incomplete($value) {
            $value.WHERE == $more-code-sentinel.WHERE;
        }

        method repl-print($value) {
            say $value unless $value eq '';
        }

        method history-file returns Str {
            return ~$!history-file if $!history-file.defined;

            $!history-file = do
                if $*ENV<RAKUDO_HIST> {
                    IO::Path.new($*ENV<RAKUDO_HIST>)
                } else {
                    IO::Path.new($*HOME).child('.perl6').child('rakudo-history')
                }
            try {
                mkpath($!history-file);

                CATCH {
                    when X::AdHoc & ({ .Str ~~ m:s/Unable to mkpath/ }) {
                        note "I ran into a problem trying to set up history: $_";
                        note 'Sorry, but history will not be saved at the end of your session';
                    }
                }
            }
            ~$!history-file
        }
    }
}
