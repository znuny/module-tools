# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2012 Znuny GmbH, https://znuny.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Console::Command::Module::Package::Install;

use strict;
use warnings;

use File::Spec ();

use Console::Command::Module::File::Link;
use Console::Command::Module::Database::Install;
use Console::Command::Module::Code::Install;

use parent qw(Console::BaseCommand);

=head1 NAME

Console::Command::Module::Package::Install - Console command to install a module

=head1 DESCRIPTION

Link a Znuny module into the framework then run database install and run code install.

=cut

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Install a module into a framework root.');
    $Self->AddArgument(
        Name        => 'module',
        Description => "Specify a module directory or collection (specified in the /etc/config.pl file).",
        Required    => 1,
        ValueRegex  => qr/.*/smx,
    );
    $Self->AddArgument(
        Name        => 'framework-directory',
        Description => "Specify directory of the framework (default: \"./\").",
        Required    => 0,
        ValueRegex  => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'verbose',
        Description => "Print detailed command output.",
        Required    => 0,
        HasValue    => 0,
        ValueRegex  => qr/.*/smx,
    );

    my $Name = $Self->Name();

    $Self->AdditionalHelp(<<"EOF");

<yellow>Installing from relative module directory</yellow>

    <green>znuny.ModuleTools.pl $Name ../MyModule ./</green>
    <green>znuny.ModuleTools.pl $Name MyModule Znuny-7_0</green>

<yellow>Installing from absolute module directory</yellow>

    <green>znuny.ModuleTools.pl $Name /Users/MyUser/ws/MyModule</green>
    <green>znuny.ModuleTools.pl $Name /Users/MyUser/ws/MyModule /Users/MyUser/ws/Znuny-7_0</green>

<yellow>Installing from module collection</yellow>

    <green>znuny.ModuleTools.pl $Name ModuleCollection</green>
EOF

    return;
}

sub PreRun {
    my ($Self) = @_;

    eval { require Kernel::Config };
    if ($@) {
        die "This console command needs to be run from a framework root directory!";
    }

    my @Directories;

    my $Module          = $Self->GetArgument('module');
    my $ModuleDirectory = File::Spec->rel2abs($Module);
    if ( !-e $ModuleDirectory || !-d $ModuleDirectory ) {
        my @Modules = @{ $Self->{Config}->{ModuleCollection}->{$Module} // [] };
        if ( !@Modules ) {
            die "$Module is not a directory or a module collection";
        }
        @Directories = @Modules;
    }

    my $FrameworkDirectory = File::Spec->rel2abs( $Self->GetArgument('framework-directory') || '.' );

    push @Directories, $FrameworkDirectory;

    for my $Directory (@Directories) {
        if ( !-e $Directory ) {
            die "$Directory does not exist";
        }
        if ( !-d $Directory ) {
            die "$Directory is not a directory";
        }
    }

    if ( !-e ( $FrameworkDirectory . '/RELEASE' ) ) {
        die "$FrameworkDirectory does not seem to be an Znuny framework directory";
    }

    return;
}

sub Run {
    my ($Self) = @_;

    my @Directories;

    my $Module               = $Self->GetArgument('module');
    my $ModuleDirectoryParam = File::Spec->rel2abs($Module);
    if ( -e $ModuleDirectoryParam ) {
        push @Directories, $ModuleDirectoryParam;
    }
    else {
        @Directories = @{ $Self->{Config}->{ModuleCollection}->{$Module} // [] };
    }

    my $FrameworkDirectory = File::Spec->rel2abs( $Self->GetArgument('framework-directory') || '.' );

    # Get Znuny major version number.
    my $ReleaseString = `cat $FrameworkDirectory/RELEASE`;
    my $MajorVersion  = '';
    if ( $ReleaseString =~ m{ VERSION \s+ = \s+ (\d+) .* \z }xms ) {
        $MajorVersion = $1;
    }

    my %Config = %{ $Self->{Config}->{TestSystem} || {} };

    if ( $MajorVersion >= 7 ) {
        $Config{ProductName}   = 'Znuny';
        $Config{ProductNameLC} = 'znuny';
    }
    else {
        $Config{ProductName}   = 'OTRS';
        $Config{ProductNameLC} = 'otrs';
    }

    # Define some maintenance commands.
    if ( $MajorVersion >= 5 ) {
        $Config{RebuildConfigCommand}
            = "sudo -u $Config{PermissionsUser} $FrameworkDirectory/bin/$Config{ProductNameLC}.Console.pl Maint::Config::Rebuild";
        $Config{DeleteCacheCommand}
            = "sudo -u $Config{PermissionsUser} $FrameworkDirectory/bin/$Config{ProductNameLC}.Console.pl Maint::Cache::Delete";
    }
    else {
        $Config{RebuildConfigCommand}
            = "sudo -u $Config{PermissionsUser} perl $FrameworkDirectory/bin/$Config{ProductNameLC}.RebuildConfig.pl";
        $Config{DeleteCacheCommand}
            = "sudo -u $Config{PermissionsUser} perl $FrameworkDirectory/bin/$Config{ProductNameLC}.DeleteCache.pl";
    }

    my $GlobalFail;

    MODULEDIRECTORY:
    for my $ModuleDirectory (@Directories) {

        # Look if an sopm exists.
        my @SOPMs = glob "$ModuleDirectory/*.sopm";

        if ( !@SOPMs || !$SOPMs[0] ) {
            $Self->PrintError("Couldn't find the SOPM file in $ModuleDirectory");
            return $Self->ExitCodeError();
        }

        my $ModuleName = $SOPMs[0];
        $ModuleName =~ s{$ModuleDirectory/(.*)\.sopm}{$1}i;

        $Self->Print("<yellow>Installing $ModuleName module...</yellow>\n\n");

        my %ExitCodes;
        my $Output;
        {

            # Localize the standard error, everything will be restored after the block.
            local *STDERR;
            local *STDOUT;

            # Redirect the standard error and output to a variable.
            open STDERR, ">>", \$Output;
            open STDOUT, ">>", \$Output;

            my $ModuleFilePath = $SOPMs[0];
            $ModuleFilePath =~ s{$ModuleDirectory/}{$FrameworkDirectory/};

            my $LinkModule = Console::Command::Module::File::Link->new();
            $ExitCodes{Files} = $LinkModule->Execute( $ModuleDirectory, $FrameworkDirectory );

            my $CodeModule = Console::Command::Module::Code::Install->new();
            $ExitCodes{CodePre} = $CodeModule->Execute( $ModuleFilePath, 'pre' );

            my $DatabaseModule = Console::Command::Module::Database::Install->new();
            $ExitCodes{DatabasePre} = $DatabaseModule->Execute( $ModuleFilePath, 'pre' );

            $Self->System( $Config{RebuildConfigCommand} );
            $Self->System( $Config{DeleteCacheCommand} );

            $ExitCodes{DatabasePost} = $DatabaseModule->Execute( $ModuleFilePath, 'post' );

            $ExitCodes{CodePost} = $CodeModule->Execute( $ModuleFilePath, 'post' );

            $Self->System( $Config{DeleteCacheCommand} );
        }

        if ( $Self->GetOption('verbose') ) {
            $Output =~ s{^}{  }mg;
            $Output =~ s{Done.}{Done.\n}mg;
            $Self->Print($Output);
        }

        my $Fail;
        EXITCODE:
        for my $ExitCode ( sort keys %ExitCodes ) {
            if ( $ExitCodes{$ExitCode} ) {
                $Fail = 1;
            }
            last EXITCODE;
        }

        if ($Fail) {
            $Self->PrintError("Could not install $ModuleName module correctly!");
            $GlobalFail = 1;
            next MODULEDIRECTORY;
        }
    }

    if ($GlobalFail) {
        return $Self->ExitCodeError();
    }

    $Self->Print("\n<green>Done.</green>\n");
    return $Self->ExitCodeOk();
}

sub System {
    my ( $Self, $Command ) = @_;

    my $Output = `$Command`;

    if ($Output) {
        $Output =~ s{^}{    }mg;
        $Self->Print($Output);
    }

    return 1;
}

1;
