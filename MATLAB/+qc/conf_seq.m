function scan = conf_seq(varargin)
	% CONF_SEQ Create special-measure scans with inline qctoolkit pulses
	%
	% Only supports inline scans at the moment (could in principle arm a
	% different program in each loop iteration using prefns but this is not
	% implemented at the moment).
	%
	% This function gets only underscore arguments to be more consistend with
	% qctoolkit. Other variables in this function are camel case.
	%
	% TODO
	% * Implement dbz feedback (use polarizefn to arm another program that has
	%   no defined measurements and thus needs no reconfiguring of the Alazar)
	%
	% --- Outputs -------------------------------------------------------------
	% scan          : special-measure scan
	%
	% --- Inputs --------------------------------------------------------------
	% varargin      : name-value pairs or parameter struct. For a list of
	%                 parameters see the struct defaultArgs below.
	%
	% -------------------------------------------------------------------------
	% (c) 2018/02 Pascal Cerfontaine (cerfontaine@physik.rwth-aachen.de)
	
	global plsdata
	
	alazarName = 'ATS9440Python';
	
	% None of the arguments except pulse_template should contain any python
	% objects to avoid erroneous saving when the scan is executed.
	defaultArgs = struct(...
		... Pulses
		'program_name',         'default_program', ...
		'pulse_template',       'default_pulse', ...
		'parameters_and_dicts', {plsdata.awg.defaultParametersAndDicts}, ...
		'channel_mapping',      plsdata.awg.defaultChannelMapping, ...
		'window_mapping',       plsdata.awg.defaultWindowMapping, ...
		'add_marker',           {plsdata.awg.defaultAddMarker}, ...
		'force_update',         false, ...
		...
		... Measurements
		'operations',           {plsdata.daq.defaultOperations}, ...
		...
		... Other
		'nrep',                 10, ...        % numer of repetition of pulse
		'fig_id',               2000, ...
		'disp_ops',            'default', ...  % list of indices of operations to show
		'disp_dim',             [1 2], ...     % dimension of display
		'delete_getchans',      [1], ...       % indices of getchans (including those generated by procfns) to delete after the scan is complete
		'procfn_ops',           {{}}, ...      % one entry for each virtual channel, each cell entry has two element: fn, args and dim.
		...                                      If there are more entreis than operations, the nth+1 entry is applied to the 1st operation again.
		'saveloop',             0, ...         % save every nth loop
		'dnp',                  false, ...     % enable DNP
		'rf_switches',          true, ...      % turn RF switches on and off automatically using the DecaDAC channels (to be removed)
		'verbosity',            10 ...         % 0: display nothing, 10: display all except when arming program, 11: display all
		);
	a = util.parse_varargin(varargin, defaultArgs);
	if ~ischar(a.pulse_template) && ~isstruct(a.pulse_template)
		a.pulse_template = qc.pulse_to_struct(a.pulse_template);
	end
	
	scan = struct('configfn', [], 'cleanupfn', [], 'loops', struct('prefn', []));
	
	% Save file and arguments with which scan was created (not stricly necessary)
	scan.data.conf_seq_fn = fileread([mfilename('fullpath') '.m']);
	scan.data.conf_seq_args = a;	
		
	% Configure channels
	scan.loops(1).getchan = {'ATSV', 'time'};	
	scan.loops(1).setchan = {'count'};
	scan.loops(1).ramptime = [];
	scan.loops(1).npoints = a.nrep;
	scan.loops(1).rng = [];
	
	nGetChan = numel(scan.loops(1).getchan);
	nOperations = numel(a.operations);
	
	% Turn AWG outputs off if scan stops (even if due to error)
	scan.configfn(end+1).fn = @qc.cleanupfn_awg;
	scan.configfn(end).args = {};	
	
	% Alazar workaround (can be removed once bug is fixed)
	scan.configfn(end+1).fn = @smaconfigwrap;
	scan.configfn(end).args = {@qc.workaround_alazar_single_buffer_acquisition};
	
	% Configure AWG
	%  * Calling qc.awg_program('add', ...) makes sure the pulse is uploaded
	%    again if any parameters changed.
	%  * If dictionaries were passed as strings, this will automatically
	%    reload the dictionaries and thus use any changes made in the
	%    dictionaries in the meantime.
	%  * The original parameters are saved in scan.data.awg_program. This
	%    includes the pulse_template in json format and all dictionary
	%    entries at the time when the scan was executed.
	%  * If a python pulse_template was passed, this will still save
	%    correctly since it was converted into a Matlab struct above.
	scan.configfn(end+1).fn = @smaconfigwrap_save_data;
	scan.configfn(end).args = {'awg_program', @qc.awg_program, 'add', a};
	
	% Configure Alazar operations
	% * alazar.update_settings = py.True is automatically set. This results
	%   in reconfiguration of the Alazar which takes a long time. Thus this
	%   should only be done before a scan is started (i.e. in a configfn).
	% * qc.dac_operations('add', a) also resets the virtual channel in
	%   smdata.inst(sminstlookup('ATS9440Python')).data.virtual_channel.
	scan.configfn(end+1).fn = @smaconfigwrap_save_data;
	scan.configfn(end).args = {'daq_operations', @qc.daq_operations, 'add', a};	
	
	% Configure Alazar virtual channel
	% * Set datadim of instrument correctly
	% * Save operation lengths in scan.data
	scan.configfn(end+1).fn = @smaconfigwrap_save_data;
	scan.configfn(end).args = {'daq_operations_length', @qc.daq_operations, 'set length', a};	
	
	% Extract operation data from first channel ('ATSV')
	% * Add procfns to scan, one for each operation
	% * The configfn qc.conf_seq_procfn sets args and dim of the first n
	%   procfns, where n is the number of operations. This ensures that start
	%   and stop always use the correct lengths even if they have changed due
	%   to changes in pulse dictionaries. qc.conf_seq_procfn assumes that the
	%   field scan.data.daq_operations_length has been set dynamically by a
	%   previous configfn.
	nGetChan = numel(scan.loops(1).getchan);
	for p = 1:numel(a.operations)
		scan.loops(1).procfn(nGetChan + p).fn(1) = struct( ...
			'fn',      @(x, startInd, stopInd)( x(startInd:stopInd) ), ...
			'args',    {{nan, nan}}, ...
			'inchan',  1, ...
			'outchan', nGetChan + p ...
			);
		scan.loops(1).procfn(nGetChan + p).dim = nan;
	end			
	scan.configfn(end+1).fn = @qc.conf_seq_procfn;
	scan.configfn(end).args = {};	
	
	if a.rf_switches
		% Turn RF switches on
		scan.configfn(end+1).fn = @smaconfigwrap;
		scan.configfn(end).args = {@smset, 'Switch1', 4};
		scan.configfn(end+1).fn = @smaconfigwrap;
		scan.configfn(end).args = {@smset, 'Switch2', 4};
		scan.configfn(end+1).fn = @smaconfigwrap;
		scan.configfn(end).args = {@pause, 0.1}; % So switches definitely on
		
		% Turn RF switches off
		scan.cleanupfn(end+1).fn = @smaconfigwrap;
		scan.cleanupfn(end).args = {@smset, 'Switch1', 0};
		scan.cleanupfn(end+1).fn = @smaconfigwrap;
		scan.cleanupfn(end).args = {@smset, 'Switch2', 0};
	end
	
	% Delete unnecessary data
	scan.cleanupfn(end+1).fn = @qc.cleanupfn_delete_getchans;
	scan.cleanupfn(end).args = {a.delete_getchans};
	
	% Allow time logging
	% * Update dummy instrument with current time so can get the current time
	%   using a getchan
	scan.loops(1).prefn(end+1).fn = @smaconfigwrap;
	scan.loops(1).prefn(end).args = {@(chan)(smset('time', now()))};
	
	% Turn AWG on
	scan.configfn(end+1).fn = @smaconfigwrap;
	scan.configfn(end).args = {@awgctrl, 'on'};
	
	% Run AWG channel pair 1
	% * Arm the program
	% * Trigger the Alazar
	% * Will later also trigger the RF switches
	% * Will run both channel pairs automatically if they are synced
	%   which they should be by default.
	% * Should be the last prefn so no other channels changed when
	%   measurement starts (really necessary?)
	scan.loops(1).prefn(end+1).fn = @smaconfigwrap;
	scan.loops(1).prefn(end).args = {@qc.awg_program, 'arm', qc.change_field(a, 'verbosity', a.verbosity-1)};
	scan.loops(1).prefn(end+1).fn = @smaconfigwrap;
	scan.loops(1).prefn(end).args = {@awgctrl, 'run', 1};
	
	% Get AWG information (not needed at the moment)
	% [analogNames, markerNames, channels] = qc.get_awg_channels();
	% [programNames, programs] = qc.get_awg_programs();
	
	% Add user procfns	
	nProcFn = numel(scan.loops(1).procfn);
	for opInd = 1:numel(a.procfn_ops) % count through operations		
		inchan = nGetChan + mod(opInd-1, nOperations)+1;
		scan.loops(1).procfn(end+1).fn(1) = struct( ...
			'fn',      a.procfn_ops{opInd}{1}, ...
			'args',    {a.procfn_ops{opInd}{2}}, ...
			'inchan',  inchan, ...
			'outchan', nProcFn + opInd ...
			);
		scan.loops(1).procfn(end).dim = a.procfn_ops{opInd}{3};
	end
	
	% Configure display
	scan.figure = a.fig_id;
	scan.disp = [];
	if strcmp(a.disp_ops, 'default')
		a.disp_ops = 1:min(4, nOperations);
	end	
	for l = 1:length(a.disp_ops)
		for d = a.disp_dim
			scan.disp(end+1).loop = 1;
			scan.disp(end).channel = nGetChan + a.disp_ops(l);
			scan.disp(end).dim = d;
			scan.disp(end).title = prepare_title(sprintf(['%s: '], a.operations{1+mod(l-1, nOperations)}{:}));
		end
	end
	
	if a.saveloop > 0
		scan.saveloop = [1, a.saveloop];
	end
	
	% Add polarization
	if a.dnp
		warning('DNP currently not implemented, but basically need to add postfn/prefn which arms a different program w/o measurements and thus w/o Alazar reconfiguration');
	end
end		
	
	
		
function str = prepare_title(str)
	
	str = strrep(str, '_', ' ');
	str = str(1:end-2);
	
end