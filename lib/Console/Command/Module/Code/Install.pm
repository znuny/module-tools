# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2012 Znuny GmbH, https://znuny.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Console::Command::Module::Code::Install;

use strict;
use warnings;
use utf8;
use File::Spec();

use parent qw(Console::BaseCommand Console::BaseModule);

=head1 NAME

Console::Command::Module::Code::Install - Console command to execute the &lt;CodeInstall&gt; section of a module.

=head1 DESCRIPTION

Runs Code install part from a module .sopm file.

=cut

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Run code install from a module .sopm file.');
    $Self->AddArgument(
        Name        => 'module-file-path',
        Description => "Specify a module .sopm file.",
        Required    => 1,
        ValueRegex  => qr/.*/smx,
    );
    $Self->AddArgument(
        Name        => 'type',
        Description => "Specify if only 'pre' or 'post' type should be executed.",
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/\A(?:pre|post)\z/smx,
    );

    return;
}

sub PreRun {
    my ($Self) = @_;

    eval { require Kernel::Config };
    if ($@) {
        die "This console command needs to be run from a framework root directory!";
    }

    my $Module = $Self->GetArgument('module-file-path');

    # Check if .sopm file exists.
    $Self->_AssertPlainFile($Module);

    return;
}

sub Run {
    my ($Self) = @_;

    my @Types;
    if ( $Self->GetArgument('type') ) {
        @Types = ( $Self->GetArgument('type') );
    }
    else {
        @Types = ( 'pre', 'post' );
    }

    $Self->Print( "<yellow>Running module code install (" . join( ',', @Types ) . ")...</yellow>\n\n" );

    my $Module = File::Spec->rel2abs( $Self->GetArgument('module-file-path') );

    # To capture the standard error.
    my $ErrorMessage = '';

    my $Success;

    {
        # Localize the standard error, everything will be restored after the block.
        local *STDERR;

        # Redirect the standard error to a variable.
        open STDERR, ">>", \$ErrorMessage;

        for my $Type (@Types) {
            $Success = $Self->CodeActionHandler(
                Module => $Module,
                Action => 'Install',
                Type   => $Type,
            );
        }
    }

    $Self->Print("$ErrorMessage\n");

    if ( !$Success || $ErrorMessage =~ m{error}i ) {
        $Self->PrintError("Couldn't run code install correctly from $Module");
        return $Self->ExitCodeError();
    }

    $Self->Print("\n<green>Done.</green>\n");
    return $Self->ExitCodeOk();
}

1;
