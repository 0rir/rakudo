# This file contains the default class for turning RakUAST::Doc::xxx
# classes into legacy pod6 objects.

class RakuAST::LegacyPodify {

    # basically mangle text to just single spaces
    my sub sanitize(Str:D $string --> Str:D) {
        $string eq "\n"
          ?? ' '
          !! $string
               .subst(/ \n+ $/)
               .subst("\n",  ' ', :global)
               .subst(/\s+/, ' ', :global)
    }

    # flatten the markup into a string, needed for V<>
    my sub flatten(RakuAST::Doc::Markup:D $markup, :$inner --> Str:D) {
        my str @parts;
        for $markup.atoms {
            @parts.push: nqp::isstr($_) ?? $_ !! flatten($_, :inner);
        }

        # V<> inside V<> *are* rendered
        if $inner {
            @parts.unshift: '<';
            @parts.unshift: $markup.letter;
            @parts.push: '>';
        }

        nqp::join('',@parts)
    }

    # produce list without last if last is \n
    my sub no-last-nl($list) {
        my $last := $list.tail;
        $list.head({ $_ - (nqp::istype($last,Str) && $last eq "\n") })
    }

    proto method podify(|) {*}

    # Base class catcher
    multi method podify(RakuAST::Doc:D $ast) {
        NYI("Podifying $ast.^name() objects").throw
    }

    # Odd value catcher, avoiding long dispatch options in error message
    multi method podify(Mu:D $ast) {
        die "You cannot podify a $ast.^name() instance: $ast.raku()";
    }
    multi method podify(Mu:U $ast) {
        die "You cannot podify a $ast.^name() type object";
    }

    multi method podify(RakuAST::Doc::Markup:D $ast) {
        my str $letter = $ast.letter;
        $letter eq 'V'
          ?? flatten($ast)
          !! Pod::FormattingCode.new(
               type     => $letter,
               meta     => $ast.meta,
               contents => $ast.atoms.map({
                   nqp::istype($_,Str)
                     ?? ($++ ?? $_ !! .trim-leading)  # first must be trimmed
                     !! self.podify($_)
               }).Slip
        )
    }

    multi method podify(RakuAST::Doc::Paragraph:D $ast) {
        Pod::Block::Para.new(
          contents => no-last-nl($ast.atoms).map({
              nqp::istype($_,Str)
                ?? sanitize($_) || Empty
                !! self.podify($_)
          }).Slip
        )
    }

    multi method podify(RakuAST::Doc::Block:D $ast) {
        my str $type  = $ast.type;
        my str $level = $ast.level;

        # this needs code of its own, as the new grammar only collects
        # and does not do any interpretation
        return self.podify-table($ast) if $type eq 'table' and !$level;

        my $config   := $ast.config;
        my $contents := no-last-nl($ast.paragraphs).map({
            if nqp::istype($_,Str) {
                if sanitize(.trim-leading) -> $contents {
                    Pod::Block::Para.new(:$contents)
                }
            }
            else {
                self.podify($_)
            }
        }).List;

        $type
          ?? $type eq 'item'
            ?? Pod::Item.new(
                 level => $level ?? $level.Int !! 1, :$config, :$contents
               )
            !! $level
              ?? $type eq 'head'
                ?? Pod::Heading.new(:level($level.Int), :$config, :$contents)
                !! Pod::Block::Named.new(
                     :name($type ~ $level), :$config, :$contents
                   )
              # from here on without level
              !! $type eq 'comment'
                ?? Pod::Block::Comment.new(:contents([$ast.paragraphs.head]))
                !! $type eq 'input' | 'output' | 'code'
                  ?? Pod::Block::Code.new(:contents([
                       no-last-nl(
                         $ast.paragraphs.head.split("\n", :v, :skip-empty).List
                       )
                     ]))
                  !! Pod::Block::Named.new(:name($type), :$config, :$contents)
          !! $contents  # no type means just a string
    }

    method podify-table(RakuAST::Doc::Block:D $ast) {
        X::NYI.new(feature => "legacy pod support for =table").throw;
    }

    multi method podify(RakuAST::Doc::Declarator:D $ast, $WHEREFORE) {
        sub normalize(@paragraphs) {
            @paragraphs.map(*.lines.map({.trim if $_}).Slip).join(' ')
        }
        my $pod := Pod::Block::Declarator.new(
          WHEREFORE => $WHEREFORE,
          leading   => [%*ENV<RAKUDO_POD_DECL_BLOCK_USER_FORMAT>
            ?? $ast.leading.join("\n")
            !! normalize($ast.leading)
          ],
          trailing  => [[normalize $ast.trailing],]
        );
        $WHEREFORE.set_why($pod);
        $pod
    }
}

# vim: expandtab shiftwidth=4
