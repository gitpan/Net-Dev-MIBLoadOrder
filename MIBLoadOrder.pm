# Perl Module
#
# Purpose:  Determine load order of a group of MIB files
#
# Written:  6/18/2003, scott.parsons    
#
# Look at end of file for all POD
#

package Net::Dev::Tools::MIB::MIBLoadOrder;

use strict;

BEGIN {
   use Exporter();
   our $VERSION = '0.9.0';
   our @ISA = qw(Exporter);

   our @EXPORT        = qw(
      mib_load
      mib_load_order
      mib_load_definitions
      mib_load_trace
      mib_load_warnings
      mib_load_error
   );

   our @EXPORT_OK     = qw();

}

our %ARGS;
our $ERROR;
our $WARNING;
our @WARNINGS;
our %DEFINITIONS;
our @STD_MIB_FILES;
our @ENT_MIB_FILES;
our %FILE_EXT;
our @WEIGHTS_SORTED;
our @LOAD_ORDER;
our $DEBUG        = 0;
our $ORDER_LOOPS  = 0;
our $_TRACK_FLAG  = 0;
our $_TRACK_INDEX = 0;
our %TRACK_HASH   = ();
our $_TYPE        ='';
our $_PRIORITY    = 0;
our $_SINGLE      = 1;
our @_EXCLUDE     = ();




##############################################################################
#
#               Functions
#
##############################################################################
#
#
sub mib_load {
   %ARGS = @_;
   %FILE_EXT    = ();
   %DEFINITIONS = ();
   $ERROR       = undef;
   @WARNINGS    = ();
   $WARNING     = undef;
   @STD_MIB_FILES = ();
   @ENT_MIB_FILES = ();
   @WEIGHTS_SORTED = ();
   $ORDER_LOOPS = 0;

   my ($_arg, $_ext, $_file, 
      $_parsed, $_sorted, $_def, $_loop,
   );
   my %_extensions;
   my $_files_found = undef;
   my $_max_loops = '1000';

   # check arguments
   foreach $_arg (keys %ARGS) {
      if    ($_arg =~ /^-?StandardMIBs$/i)     {next;}
      elsif ($_arg =~ /^-?EnterpriseMIBs$/i)   {next;}
      elsif ($_arg =~ /^-?Extensions$/i)       {next;}
      elsif ($_arg =~ /^-?exclude$/i)          {next;}
      elsif ($_arg =~ /^-?track$/i)            {$_TRACK_FLAG = delete($ARGS{$_arg});}
      elsif ($_arg =~ /^-?prioritize$/i)       {$_PRIORITY   = delete($ARGS{$_arg});}
      elsif ($_arg =~ /^-?singlefile$/i)       {$_SINGLE     = delete($ARGS{$_arg});}
      elsif ($_arg =~ /^-?maxloops$/i)         {$_max_loops  = delete($ARGS{$_arg});}
      elsif ($_arg =~ /^-?debug$/i)            {$DEBUG       = delete($ARGS{$_arg});}
      else  {
         $ERROR = "unsupported argument: [$_arg]";
         return wantarray ? (undef, undef, $ERROR) : undef;
      }
   }

   # see what extensions to check for
   if (defined($ARGS{Extensions})) {
      foreach $_ext ( @{$ARGS{Extensions}} ) {
         $FILE_EXT{$_ext} = 1;
         _myprintf("File Extension check: %s [%s]\n", $_ext, $FILE_EXT{$_ext});
      }
   }
   else {
      $FILE_EXT{mib} = 1;
      _myprintf("File Extension check: %s [%s], default\n", 'mib', $FILE_EXT{mib});
   }

   # see what dirs and/or files are given
   _myprintf("Examine StandardMIBs list\n");
   if (defined($ARGS{StandardMIBs})) {
      foreach $_file ( @{$ARGS{StandardMIBs}} ) {
         $_files_found = _scan_file_list('Standard', $_file);
         if ($_files_found) {
            _myprintf("Files found: %s contains %s files\n", $_file, $_files_found);
         }
         else {
            return wantarray ? (undef, undef, $ERROR) : undef;
         }
      }
   }
   _myprintf("Examine EnterpriseMIBs list\n");
   if (defined($ARGS{EnterpriseMIBs})) {
      foreach $_file ( @{$ARGS{EnterpriseMIBs}} ) {
         $_files_found = _scan_file_list('Enterprise', $_file);
         if ($_files_found) {
            _myprintf("Files found: %s contains %s files\n", $_file, $_files_found);
         }
         else {
            return wantarray ? (undef, undef, $ERROR) : undef;
         }
      }
   }

   # parse the files
   foreach $_file ('TYPE::STD', @STD_MIB_FILES, 'TYPE::ENT', @ENT_MIB_FILES ) {
      # determine type
      if ($_file eq "TYPE::STD") {$_TYPE = 'Standard'; next;}
      if ($_file eq "TYPE::ENT") {$_TYPE = 'Enterprise'; next;}

      $_parsed = _parse_mib_file($_file);
      unless ($_parsed) {
         return wantarray ? (undef, undef, $ERROR) : undef;
      }
   }

   # compute the weights for the definitions
   _compute_definition_weights();

   # prioritize
   # look at enterprise weights, make all standard weights higher
   if ($_PRIORITY) { _prioritize(); }

   # find the warnings
   _find_warnings();


   # sort weights and sort definitions until the 
   # &_sort_definitions() returns true

   do {
      ++$ORDER_LOOPS;

      if ($ORDER_LOOPS == $_max_loops) {
          $ERROR = "max loops $_max_loops excedded";
          return wantarray ? (undef, undef, $ERROR) : undef;
      }

      foreach $_def (sort keys %DEFINITIONS) {
         _track_it("$_def", "SORTING Weights and DEFINITIONS, loop $_loop");
      }
      # sort the values for the weight
      _sort_weights();

      # from sorted weights, make list 
      $_sorted = _sort_definitions();
   } until $_sorted;

   return wantarray ? (\@LOAD_ORDER, scalar(@WARNINGS), $ERROR) : \@LOAD_ORDER;
}   # end sub new


##############################################################################
#
#        Return Reference Functions
#
##############################################################################
#
# functions to return variables or references to variables

sub mib_load_order        { return(\@LOAD_ORDER); }
sub mib_load_definitions  { return(\%DEFINITIONS); }
sub mib_load_trace        { return(\%TRACK_HASH); }
sub mib_load_warnings     { return(\@WARNINGS); }
sub mib_load_error        { return($ERROR); }



##############################################################################
#
#                       Private Functions
#
##############################################################################
#
# Purpose: function to scan file list
#
# Arguments:
#   $_[0] = Source (Standard or Enterprise)
#   $_[1] = file
#
# Return 
#  Integer indicating how many files found
#  or undef on error
#
sub _scan_file_list {

   my $_tag      = $_[0];
   my $_chk_file = $_[1];
   my $_match    = undef;
   my ($_f, $_chk_ext, $_fullname, $_separator);
   my @_mib_files = ();

   $ERROR = "$_chk_file: unable to scan";

   _myprintf("  Examining %s list item: [%s]\n", $_tag, $_chk_file);
   # see what our dir separator is
   # store it and strip it off the end
   #
   if     ($_chk_file =~/\//) {$_separator = '/';  $_chk_file =~ s/\/$//;}
   elsif  ($_chk_file =~/\\/) {$_separator = '\\'; $_chk_file =~ s/\\$//;}

   $_chk_file =~ s/\/$//;
   # see if its a directory
   if (-e $_chk_file and -d $_chk_file) {
      _myprintf("  Determined %s list item: [%s] to be dir\n", 
         $_tag, $_chk_file
      ) ;
      if (!-r $_chk_file) {
         $ERROR = "$_tag: $_chk_file not readable";
         _myprintf("   $_tag: $_chk_file not readable");
         return(undef); 
      }
      # read the files in the directory 
      opendir(DIR, $_chk_file);
      while ($_f = readdir(DIR)) {
         next if $_f =~ /^\.$/;
         next if $_f =~ /^\..$/;
         # check the file extension 
         if ($_f =~ /\.(.+)$/) {
            $_chk_ext = $1;
            if (defined($FILE_EXT{$_chk_ext})) {
               $_fullname = sprintf("%s%s%s", $_chk_file, $_separator, $_f);
               $_match++;
               push(@_mib_files, $_fullname);
               _myprintf("  MIB file: %s: found: [%s] [%s] \n", 
                  $_tag, $_f, $_fullname 
              ) ;
            }
         }
      }
      closedir(DIR);
   }
   # see if its a file
   elsif (-e $_chk_file and -f $_chk_file) {
      _myprintf("  Determined %s list item: [%s] to be file\n", $_tag, $_chk_file) ;
      if (!-r $_chk_file) {
         $ERROR = "$_tag: $_chk_file not readable";
         return(undef);
      }
      # check the file extension
      if ($_chk_file =~ /\.(.+)$/) {
         $_chk_ext = $1;
         if (defined($FILE_EXT{$_chk_ext})) {
            _myprintf("  MIB file: %s: found: %s\n", $_tag, $_chk_file) ;
            $_match++;
            push(@_mib_files, $_chk_file);
         }
      }
   }
   if (scalar(@_mib_files)) {
     if ($_tag =~ /Standard/)   {push(@STD_MIB_FILES, @_mib_files);}
     if ($_tag =~ /Enterprise/) {push(@ENT_MIB_FILES, @_mib_files);}
   }

   return($_match);
}    # end _scan_file_list 

#
#.............................................................................
#
# function to parse the MIB file
# populate global hashes
#
# Arguments
#  $_[0] = file
# 
# Return
#  (success, error)
#     success = 1 or undef
#
sub _parse_mib_file {
   my $_definition_count = 0;
   my $_definition       = undef;
   my $_import_flag      = '0';
   my $_import           = undef;
   my $_import_count     = 0;
   my $_excl;
   my $_match            = 0;

   $ERROR = "$_[0]: failed to parse mib file"; 

   _myprintf("PARSING: %s\n", $_[0]) ;

   # see if we are excluding, check filename for pattern
   if ( defined($ARGS{exclude})) { 
      foreach $_excl ( @{$ARGS{exclude}} ) {
         if ($_[0] =~ /$_excl/) {
            $_match++;
            $WARNING = "exclusion match [$_excl] on [$_[0]]";
            push(@WARNINGS, ['_EXCL_', "$WARNING"]);
            _myprintf("Exclusion: %s\n",  $WARNING);
         }
      }
      return(1)  if $_match;
   }

   # open and parse the file
   close(MIB) if (MIB);
   open(MIB, "$_[0]") || return (undef, "can not open $_[0]: $!");
   while(<MIB>) {
      if (/^$/)      {next;}
      if (/^\s+$/)   {next;}
      if (/^--/)     {next;}
      if (/^\s+--/)  {next;}
      # parse out definitions
      if (/([\w\d-]+)\b\s+DEFINITIONS\s+::=\s+BEGIN/) {
         $_definition = $1;
         $_definition_count++;
         _myprintf("   DEFINITION parsed: line %-4s count: %3s %s [%s]\n", 
            $., $_definition_count, $_TYPE, $_definition
         );
         _track_it("$_definition", "defined in [$_[0]], line: $. type: $_TYPE");
         # error out if more than one definition per file
         if ($_definition_count > 1) {
            $ERROR = "multiple DEFINITION in $_[0]";
            close(MIB);
            return (undef);
         }
         push(@{$DEFINITIONS{$_definition}{files}}, $_[0]);
         $DEFINITIONS{$_definition}{type} = $_TYPE;
         _track_it("$_definition", "adding $_TYPE [$_[0]] to file list");
      }
      # Detect IMPORTS, enable parsing
      if (/IMPORTS/) {
         if (!$_definition) {
            $ERROR = "IMPORTS found before DEFINITION: line $. $_[0]";
            return (undef);
         }
         $_import_flag = 1;
      }
      # parse out IMPORTS
      if ($_import_flag) {
         if ( /FROM.+FROM/ ) {
            $ERROR = sprintf("multiple FROMs at line %s of file %s", $., $_[0]);
            close(MIB);
            return (undef);
         }
         if (/FROM\s+\b(.+)\b/) {
             $_import = $1;
             push(@{$DEFINITIONS{$_definition}{imports}}, $_import);
             _myprintf("   IMPORT parsed:     line %-4s  %3s imports [%s]\n", 
                $., scalar(@{$DEFINITIONS{$_definition}{imports}}),  $_import
             );
             _track_it("$_definition", "requires IMPORT $_import, line: $.");
             _track_it("$_import", "required import for $_definition");
         }

      }
      # disable IMPORT parse when we see a ';'
      if ($_import_flag) {
         if    (/;/)       {$_import_flag = 0;}
         elsif (/;$/)      {$_import_flag = 0;}
         elsif (/;\s+$/)   {$_import_flag = 0;}
         elsif (/\w;/)     {$_import_flag = 0;}
         else              {$_import_flag = 1;}
         # clear the definition after import section
         if ($_import_flag == 0) {$_definition = undef;}
      }
   }
   close(MIB);
   # if no definition found, issue warning
   if ($_definition_count == 0) {
      $WARNING = sprintf("No DEFINITION parsed in: [%s]", $_[0]);
      push(@WARNINGS, ['_FILE_', $WARNING] );
   }

   return(1);
}   # end _parse_mib_file

#
#.............................................................................
#
#
# function to compute the weights of the DEFINITIONS
#
# Arguments
#  none, work on global hash
#
# Return
#  none, populate global hash
sub _compute_definition_weights {

   my $_base_weight     = 2;      # all definitions get this
   my $_import_required = '-1';   # if definition requires imports
   my $_import_weight   = 5;      # apply to all imports
   my $_import2_weight  = 1000;   # apply to all imports required by prev import

   my ($_def, $_imp, $_imp2);

   # loop thru each definition
   # add $_base_weight for each definition
   my $_c = 0;
   foreach $_def (sort keys %DEFINITIONS) {
      $DEFINITIONS{$_def}{weight} = $DEFINITIONS{$_def}{weight} + $_base_weight;
      _myprintf("Weight \(%s\): %s defined, incr %s, weight = %s\n", 
         ++$_c, $_def, $_base_weight, $DEFINITIONS{$_def}{weight}
      );
      _track_it($_def, "adding base weight: $_base_weight, now $DEFINITIONS{$_def}{weight}");
      # if this definition requires imports, add $_import_required (subtraction) 
      if (scalar($DEFINITIONS{$_def}{imports})) {
         $DEFINITIONS{$_def}{weight} = $DEFINITIONS{$_def}{weight} + $_import_required;
         _myprintf("  Weight: requires IMPORTs, decr %s, weight = %s\n",
            $_import_required, $DEFINITIONS{$_def}{weight}
         );
         _track_it($_def, 
            "requires imports, decr $_import_required, now $DEFINITIONS{$_def}{weight}"
         );
         # foreach import required, add $_import_weight to the import's definition
         foreach $_imp (@{$DEFINITIONS{$_def}{imports}}) {
             $DEFINITIONS{$_imp}{weight} = $DEFINITIONS{$_imp}{weight} + $_import_weight;
             _myprintf("  Weight: required IMPORT: [%s] incr %s, weight = %s\n",
                  $_imp, $_import_weight, $DEFINITIONS{$_imp}{weight}
             );
             _track_it($_imp, 
                "required IMPORT for $_def, incr $_import_weight, now $DEFINITIONS{$_imp}{weight}"
             );
             # if import requires import, add $_import2_weight to what it imports
             if (scalar($DEFINITIONS{$_imp}{imports})) {
                foreach $_imp2 (@{$DEFINITIONS{$_imp}{imports}}) {
                   $DEFINITIONS{$_imp2}{weight} = $DEFINITIONS{$_imp2}{weight} + $_import2_weight;
                   _myprintf("    Weight: IMPORT requires: [%s], incr %s, weight = %s\n",
                      $_imp2, $_import2_weight, $DEFINITIONS{$_imp2}{weight}
                   );
                   _track_it($_imp2, 
                      "required by import $_imp, incr $_import2_weight, now $DEFINITIONS{$_imp2}{weight}"
                   );
                }
             }
         }         
      }
   }
   1;
}
#
#.............................................................................
#
# function to prioritize standard mibs over enterprise mibs
# look at all enterprise mib definitions, find highest weight
# look at all standard mibs, if weight is lower, make it '1' more than
# highest enterprise
#
# Arguments
#  none, works on global hash
#
# Return
#  none, works on global hash
#
sub _prioritize {

  my $_ent_max = 0;
  my ($_def, $_prev_weight);

  # find highest enterprise weight
  foreach $_def (keys %DEFINITIONS) {
      if ($DEFINITIONS{$_def}{type} eq "Enterprise") {
         if ($DEFINITIONS{$_def}{weight} > $_ent_max)
            {$_ent_max = $DEFINITIONS{$_def}{weight};}
      }
   }
   _myprintf("highest Enterprise MIB weight = %s\n", $_ent_max);

   # check each standard mib, if weight is less than or equal to highest
   # enterprise mib, change standard weight to +1 of highest enterprise
   # this will not corrupt order, another filter will assure proper order
   # this will only get as many standared mibs in front of enterprise mibs 
   # as possible
   foreach $_def (keys %DEFINITIONS) {
      if ( $DEFINITIONS{$_def}{type} eq "Standard") {
         if ($DEFINITIONS{$_def}{weight} <= $_ent_max ) {
             $_prev_weight = $DEFINITIONS{$_def}{weight};
             $DEFINITIONS{$_def}{weight} = $_ent_max + 1;
             _myprintf("%s %s [%s] weight less than highest enterprise, change to %s\n",
                $DEFINITIONS{$_def}{type},
                $_def,
                $_prev_weight,
                $DEFINITIONS{$_def}{weight},
             ); 
             _track_it("$_def", 
                "priority change, $_prev_weight <= $_ent_max, change to $DEFINITIONS{$_def}{weight}"
             );
         }
      }
   }
   1;
}
#
#.............................................................................
#
# function to sort the weights
#
# Arguments
#  none, get info from global hash
#
# Return
#   none, make global array, sorted weight
#

sub _sort_weights {

   my @_weights_unsorted = ();
   my %_weights          = ();
   my $_def_count        = 0;
   my ($_d);

   @WEIGHTS_SORTED = ();

   # extract and index the weights
   foreach $_d (keys %DEFINITIONS) {
      $_def_count++;
      $_weights{$DEFINITIONS{$_d}{weight}} = $_weights{$DEFINITIONS{$_d}{weight}} + 1;
      _myprintf("sorting: weight %s, [%s] %s DEFINITIONs\n",
         $DEFINITIONS{$_d}{weight}, $_d, $_weights{$DEFINITIONS{$_d}{weight}},
      );
      _track_it("$_d", "sorted weight is $DEFINITIONS{$_d}{weight}");
   }
   @_weights_unsorted = keys %_weights;

   @WEIGHTS_SORTED =  reverse sort {$a <=> $b} @_weights_unsorted;

   if ($DEBUG) {
      foreach (@WEIGHTS_SORTED) 
         {_myprintf("weight sort summary: weight %8s  %s definitions\n", $_, $_weights{$_});}
   }
   _myprintf("%s sorted definitions\n", $_def_count);
   1;
}
#
#.............................................................................
#
# function to make a sorted list of definitions based on sorted weight list
#
# Arguments
#   none, read from global hash
#
# Return
#   none, make global list

sub _sort_definitions {

   my ($_w, $_def, $_imp, $_d);
   my $_ok = undef;

   @LOAD_ORDER = ();

   _myprintf("### Sorting DEFINITIONs, loop: %s ###\n", $ORDER_LOOPS);
   # cycle through each weight
   foreach $_w (@WEIGHTS_SORTED) {
      _myprintf("weight: %8s\n", $_w);
      # find DEFs with this weight
      foreach $_def (keys %DEFINITIONS) {
         if ($DEFINITIONS{$_def}{weight} == $_w) {
            push(@LOAD_ORDER, $_def);
            _myprintf("  [%s] = %s, added to load ordered, %s loaded\n",
               $_def, $DEFINITIONS{$_def}{weight}, scalar(@LOAD_ORDER),
            );
            _track_it("$_def", 
               "sorting definition, pushing on load order list, $DEFINITIONS{$_def}{weight}"
            );
            # check that its imports are loaded, based on weight
            foreach $_imp (@{$DEFINITIONS{$_def}{imports}}) {
               _myprintf("    IMPORT [%s] required, ", $_imp);
               # check weights of any imports are greater than definition weight
               if ($DEFINITIONS{$_imp}{weight} <= $_w) {
                  printf("not loaded, changing weight %s => ",
                     $DEFINITIONS{$_imp}{weight}
                  ) if $DEBUG;
                  _track_it("$_imp",
                     "required IMPORT has lower weight: $DEFINITIONS{$_imp}{weight}"
                  );
                  $DEFINITIONS{$_imp}{weight} = $_w + 1;
                  printf("%s\n", $DEFINITIONS{$_imp}{weight}) if $DEBUG;
                  _track_it("$_imp", 
                     "changed weight to $DEFINITIONS{$_imp}{weight} for requirements"
                  );
                  # update the tracking that we are resorting
                  unless ($_TRACK_FLAG) {
                     foreach $_d (keys %DEFINITIONS) 
                        {_track_it("$_d","re-sort, $_def requires $_imp to be loaded");}
                  }
                  return(undef);
               }
               # all imports have higher weights
               else {
                  printf("loaded, %s\n", $DEFINITIONS{$_imp}{weight})
                  if  $DEBUG;
               }
            }
         }
      }
   }
   _myprintf("DEFINITIONs sorted, %s loops needed\n", $ORDER_LOOPS);
   1;
}
#
#.............................................................................
#
# function to find the warnings
# 
# loop thru all definitions, if no files exist for def, issue warning
#
# Arguments
#   none, operate on global hash
#
# Return
#  none, populate globah hash
#      @WARNINGS = ([DEFINITION, cuase], [], []
#
sub _find_warnings {

   my $_no_file     = 'No file found for DEFINITION';
   my $_multi_files = 'DEFINITION found in multiple files';
   my $_def;
   my $_keep;
   my @_dump;
   my $_f;
   
   foreach $_def (sort keys %DEFINITIONS) {
      if ( !defined(@{$DEFINITIONS{$_def}{files}}) ) {
         push(@WARNINGS, ["$_def", "$_no_file"]);
         _track_it("$_def", "issue warning: $_no_file");
      }
      if ( scalar(@{$DEFINITIONS{$_def}{files}}) > 1 ) {
          push(@WARNINGS, ["$_def", "$_multi_files"]);
          _track_it("$_def", "issue warning: $_multi_files");
          # just keep one file if desired
          if ($_SINGLE == 1) { 
             ($_keep, @_dump) = @{$DEFINITIONS{$_def}{files}};
             @{$DEFINITIONS{$_def}{files}} = $_keep;
             _track_it("$_def", "keep only 1 file: $_keep");
             foreach $_f (@_dump) {
                _myprintf("multiple files: removed [%s]\n", $_f);
                _track_it("$_def", "remove file from list: $_f");
                 push(@WARNINGS, ["$_def", "remove file from list: $_f"]); 
             }
          } 
      }
   }
   1;
}
#
#.............................................................................
#
#
sub _myprintf {

  return unless $DEBUG;

   my $_format = shift;
   my ($_pkg, $_line) = (caller)[0,2];
   my $_func = (caller(1))[3];
   $_pkg =~ s/.+://;
   $_func =~ s/.+://;

   printf("%s: %s: [%s]:  $_format", $_pkg, $_func, $_line, @_);
}

#
#.............................................................................
#
# function to track events per DEFINITION
#
# Argument
#   $_[0] = DEFINITION
#   $_[1] = event
#
# Return
#   none, populate global hash
#   %TRACK{definition} = ([index, event], [], [], ...)
# 
sub _track_it {
   return unless $_TRACK_FLAG;
   push( @{$TRACK_HASH{$_[0]}}, [++$_TRACK_INDEX, "$_[1]"] );     
   1;
}



#
# !!!!  End the Module   !!!!
#

1;
__END__

#=============================================================================
#
#                                 POD
#
#=============================================================================

=pod

=head1 NAME

MIBLoadOrder - Parse MIB files and determine MIB Load Order.

=head1 VERSION

MIBLoadOrder Version 1.0.0

=head1 SYNOPSIS

    use MIBLoadOrder;

    ($load, $warn, $error) = mib_load(
       -StandardMIBs    =>  @StandardMIBs,   
       -EnterpriseMIBs  =>  @EnterpriseMIBs,
       -Extensions      =>  %FileExtensions,
       -track           =>  0|1,
       -prioritize      =>  0|1,
       -singlefile      =>  0|1,
       -maxloops        =>  Integer,
       -debug           =>  0|1,
    );


    mib_load_order();
    @MIBLoadOrder::@LOAD_ORDER
    
    mib_load_definitions();
    %MIBLoadOrder::DEFINITIONS

    mib_load_warnings();
    @MIBLoadOrder::WARNINGS

    mib_load_error();
    $MIBLoadOrder::ERROR

    mib_load_trace()
    %MIBLoadOrder::TRACK_HASH

    mib_load_error
    $MIBLoadOrder::ERROR

=head1 DESCRIPTION

Module provides function that will scan a list of files
and/or directories to find MIB files. Then parse each MIB file for the
information required to determine a MIB Load Order for a NMS.


=head1 REQUIRES

No special requirements.

=head1 EXPORTS

    Functions
        mib_load                  # create load order
        mib_load_order            # access to load order list
        mib_load_definitions      # access to definition info
        mib_load_trace            # access to trace info
        mib_load_warnings         # access to warning list
        mib_load_error            # access to last error message

=head1 FUNCTIONS

=head2 mib_load

    ($load, $warn, $error) = mib_load(
       -StandardMIBs    =>  \@StandardMIBs,   
       -EnterpriseMIBs  =>  \@EnterpriseMIBs,
       -Extensions      =>  \@FileExtensions,
       -exclude         =>  \@ExcludePatterns,
       -track           =>  0|1,
       -prioritize      =>  0|1,
       -singlefile      =>  0|1,
       -maxloops        =>  Integer,
       -debug           =>  0|1,
    );

    The mib_load function will return in array context, a reference to an ordered
    list of MIB DEFINITIONs, integer value of warnings, the last error.
    In scalar context, just a reference to an ordered list of MIB DEFINITIONs.
    If error, $load, $warn are undefined and $error is true, it is a character string
    describing the error.

At least one argument, StandardMIBs or EnterpriseMIBs, is needed.
The rest will default values.
The intent of these two different arguments is to allow the user
to maintain their own location of Standard MIBs, then if a vendors
set of MIB files also include Standard MIB's, the Load Order determined
with this method can be configured to only list the 'first file found',
thus the StandardMIBs locations.

Or this can be used to assure that certain files are put in the order first.
StandardMIBs is search before EnterpriseMIBs. As a DEFINITION is found, the
file that it was found in is stored with that DEFINITION. It is possible for
a DEFINITION to be found in multiple files, it is the responsibility of the 
user to know how they want to handle this situation.


=over 4

=item StandardMIBs

    Reference to list of directories and/or files that define 
    Standard MIBs. Read before EnterpriseMIBs.

=item EnterpriseMIBs

    Reference to list of directories and/or files that define 
    Enterprise MIBs. Read after StandardMIBs.

=item Extensions

    Reference to list of file extensions.
    Files with any of these extensions are parsed.

=item exclude

    Reference to a list of patterns, if a pattern is matched in
    in a filename, that file will not be parsed for DEFINITION.


=item track

    Flag to enable or disable tracking.
    0 disable tracking, default is 0.
    Tracking is down per MIB DEFINITION, each time an action
    is applied to a DEFINITION, the action is recorded in
    a public accessible hash.

=item prioritize

    Flag to enable or disable prioritization.
    0 disable prioritization, default is 0.
    Prioritization trys to place all DEFINITIONs found in 
    StandardMIBs before any found in EnterpriseMIBs when 
    calculating weights. The highest weight applied to an 
    EnterpriseMIBs is found, all StandardMIBs are then made 1 
    greater than this, if not already greater. This does not 
    corrupt load order, if a StandardMIBs DEFINITION still needs 
    the EnterpriseMIBs DEFINITION loaded, this will be done.

=item singlefile

    Only store a single file for a DEFINITION.
    1 enables this feature, default is 1.
    If a DEFINITION is found in more than one file, only the first
    file found with the DEFINITION is kept, all other files are 
    not stored. The first file found will be influenced by the 
    order of StandardMIBs list items, then EnterpriseMIBs.

=item maxloops

    The max number of times to sort weights.
    Default value is 1000.
    This allows the user to prevent continous loops.
    If max number is reached, no Load Order is determined.

=item debug

    Flag to enable or disable debugging to STDOUT.
    0 disables debugging, default is 0.
    1 enables debugging.

=back

=head2 Variable Access

=head3 Load Order

    Direct Access
        @MIBLoadOrder::@LOAD_ORDER

    Function, returns a reference to array.
        mib_load_order()

    Array syntax
        (DEFINITION, DEFINITION, DEFINITION, ....)

=head3 MIB Definitions

    Direct Access
        %MIBLoadOrder::DEFINITIONS

    Function, returns a reference to hash
        mib_load_definitions()

    Hash Syntax
        %DEFINITIONS{<definition>}{files}   = (file, file, ....)
        %DEFINITIONS{<definition>}{type}    = Standard | Enterprise
        %DEFINITIONS{<definition>}{imports} = (DEFINITION, DEFINITION, ...)
        %DEFINITIONS{<definition>}{weight}  = calculated weight

=head3 Warnings

    Direct Access
        @MIBLoadOrder::WARNINGS

    Function, returns a reference to array of arrays
        mib_load_warnings()

    Array Syntax
        ([<definition>, warning], [<definition>, warning], ...)


=head3 Errors

    Direct Access
        $MIBLoadOrder::ERROR

    Function, returns a string indicating the last error
        mib_load_error()

=head3 Tracking

    Direct Access
        %MIBLoadOrder::TRACK_HASH

    Function, returns a reference to hash
        mib_load_trace()

    Hash syntax
        %TRACK{<definition>} = ([index, event], [index, event], ...)

        where 
           index = sequence number of the event
           event = description of event

=head3 Other Variables

    @MIBLoadOrder::WEIGHTS_SORTED = list of unique weights

    $MIBLoadOrder::ORDER_LOOPS  = the number of loops the sort routine ran.

    @MIBLoadOrder::STD_MIB_FILES = list of files tagged as Standard

    @MIBLoadOrder::ENT_MIB_FILES = list of files tagged as Enterprise

    %MIBLoadOrder::FILE_EXT = hash of desired file extension


=head1 Operation

The following details how this module works.

The mib_load function will read in and check all arguments.
Dummy checks are done before any files are found and subsequently parsed. 
If file extension are given with -Extensions, they are stored, otherwise
the extension 'mib' is used.

The files or directories given with StandardMIBs and EnterpriseMIBs
are checked and put onto a file list. StandardMIBs is search first,
then EnterpriseMIBs. If files or directories are not found for a given
argument, then an error is returned. Each item in the StandardMIBs and 
EnterpriseMIBs list is examined, if it is a file that matches desired
extensions, it is stored. If the item is a directory, then all files
are check to see if they match the desired extensions, if so, the file
is stored.

Each file stored is then parsed for DEFINITIONs and IMPORTs.
If -exclude is defined and the file matches any string in the 
exclude list, that file is not parsed, a warning is issued, denoted as _EXCL_.
If no DEFINITION is found, a warning is stored, denoted as _FILE_.
If more than one DEFINTITION is found in a file, error is returned.

Weights are determined per DEFINITION. 
Each DEFINITION is  assigned a weight of 2.
If a DEFINITION requires IMPORTs, its weight is decremented by 1.
For each IMPORT required, the IMPORT DEFINITION is incremented by 5.
If an IMPORT requires IMPORTs, then those IMPORT DEFINITION weights
are incremented by 1000.

If prioritization is enabled, then the highest Enterprise DEFINITION weight
is found. Then all StandardMIBs DEFINTION weights are checked, if their weight
is less than the highest EnterpriseMIB weight, the StandardMIB weight
is made one greater than the highest EnterpriseMIB weight.


All DEFINITIONs are check for warnings.
If no files are stored for a DEFINITION, a warning is issued.
If a DEFINITION has more than one file, a warning is issued, 
and if -singlefile is true (1), than only the first file is kept. 
If files are dumped a warning is issued.

Enter a loop to sort all weights. Each DEFINITION is examined, 
each unique weight is stored. After all weights have been learned, they
are sorted in descending order. For each weight, search all DEFINITIONs,
if a DEFINITION has this weight, check that all its IMPORTS have a weight
greater than the current weight. If a IMPORT DEFINITION has a lower weight
then change its weight to one more than the current DEFINITIONs weight and 
re-start the loop. This loop will continue until all DEFINITIONs have
IMPORTS with higher weights. Once this is complete, the method exits
as successful. If -maxloops is exceeded before the loop can complete
the method exits with error. If successful, the user can now access
load order info.


=head1 Example

=head2 Determine Load Order, use direct access to variables

    #!/usr/bin/perl
    #
    # Purpose:  Script to test mib load order module
    #
    
    use strict;
    use Net::Dev::Tools::MIB::MIBLoadOrder;
    
    our $MIBLOAD;
    
    my $track = 0;
    
    my ($error, $warn, $def, $file, $trace);
    my @standard_mibs   = ('/usr/local/share/mibs/fore/Standard',
                           '/usr/local/share/snmp/mibs',
    );
    my @enterprise_mibs = ('/usr/local/share/mibs/fore/Enterprise');
    my @extensions      = ('mib', 'txt');
    ($MIBLOAD, $warn, $error) = mib_load(
       StandardMIBs   => \@standard_mibs, 
       EnterpriseMIBs => \@enterprise_mibs,
       Extensions     => \@extensions,
       track          => $track,
       prioritize     => '0',
       singlefile     => '1',
       maxloops       => '100',
       debug          => '0',
    );
    
    unless ($MIBLOAD) {
       printf("Method failed: %s\n",  $error);
       exit(1);
    }
    if ($warn) {
       printf("Warnings\n");
       foreach (@Net::Dev::Tools::MIB::MIBLoadOrder::WARNINGS) 
          {printf("   %-20s  %s\n", $_->[0], $_->[1]);}
    }
    print "="x79, "\n";
    
    foreach $def (@{$MIBLOAD}) {
       printf("%-35s %-10s [%s]  ", 
          $def,
          $Net::Dev::Tools::MIB::MIBLoadOrder::DEFINITIONS{$def}{type} || '-', 
          $Net::Dev::Tools::MIB::MIBLoadOrder::DEFINITIONS{$def}{weight}
       );
       if (@{$Net::Dev::Tools::MIB::MIBLoadOrder::DEFINITIONS{$def}{files}}) {
          foreach  $file (@{$Net::Dev::Tools::MIB::MIBLoadOrder::DEFINITIONS{$def}{files}}) 
             {printf("%s\n", $file);}
       }
       else 
          {printf("--\n");}
    
       if ($track) {
           foreach $trace (@{$Net::Dev::Tools::MIB::MIBLoadOrder::TRACK_HASH{$def}} ) 
               {printf("\t    %-4s %s\n", $trace->[0], $trace->[1]);} 
           }
    }

    exit(0);





=head2 Determine Load Order, use reference to variables

    #!/usr/bin/perl
    #
    # Purpose:  Script to test mib load order module
    #
    
    use strict;
    use Net::Dev::Tools::MIB::MIBLoadOrder;
    
    our $MIBLOAD;
    
    my $track = 0;
    
    
    my ($lo_ref, $ld_ref, $lt_ref, $lw_ref);
    my ($error, $warn, $def, $file, $trace);
    my @standard_mibs   = ('/usr/local/share/mibs/fore/Standard',
                           '/usr/local/share/snmp/mibs',
    );
    my @enterprise_mibs = ('/usr/local/share/mibs/fore/Enterprise');
    my @extensions      = ('mib', 'txt');
    
    
    my @exclude = ('foobar');
    ($MIBLOAD, $warn, $error) = mib_load(
       StandardMIBs   => \@standard_mibs, 
       EnterpriseMIBs => \@enterprise_mibs,
       Extensions     => \@extensions,
       track          => $track,
       prioritize     => '1',
       singlefile     => '0',
       maxloops       => '100',
       exclude        => \@exclude,
       debug          => '0',
    );
    
    unless ($MIBLOAD) {
       printf("Method failed: %s\n",  $error);
       exit(1);
    }
    if ($warn) {
       $lw_ref = mib_load_warnings();
       printf("Warnings\n");
       foreach (@{$lw_ref}) {printf("   %-20s  %s\n", $_->[0], $_->[1]);}
    }
    print "="x79, "\n";
    
    $lo_ref = mib_load_order();
    $ld_ref = mib_load_definitions();
    $lt_ref = mib_load_trace();
    
    foreach $def (@{$lo_ref}) {
       printf("%-35s %-10s [%s]  ", 
          $def,
          $ld_ref->{$def}{type} || '-', 
          $ld_ref->{$def}{weight}
       );
       if (@{$ld_ref->{$def}{files}}) {
          foreach  $file (@{$ld_ref->{$def}{files}}) 
             {printf("%s\n", $file);}
       }
       else 
          {printf("--\n");}
    
       if ($track) {
       foreach $trace (@{$lt_ref->{$def}} ) 
          {printf("\t    %-4s %s\n", $trace->[0], $trace->[1]);} 
       }
    }
    
    exit(0);


=head1 AUTHOR

    sparsons

=head1 COPYRIGHT

    Copyright (c) 2003 Scott Parsons All rights reserved.
    This program is free software; you may redistribute it 
    and/or modify it under the same terms as Perl itself.




=cut
