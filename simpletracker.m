function [ tracks, adjacency_tracks, A ] = simpletracker(points, varargin)
% SIMPLETRACKER  a simple particle tracking algorithm that can deal with gaps
%
% *Tracking* , or particle linking, consist in re-building the trajectories
% of one or several particles as they move along time. Their position is
% reported at each frame, but their identiy is yet unknown: we do not know
% what particle in one frame corresponding to a particle in the previous
% frame. Tracking algorithms aim at providing a solution for this problem.
%
% |simpletracker.m| is - as the name says - a simple implementation of a
% tracking algorithm, that can deal with gaps. A gap happens when one
% particle that was detected in one frame is not detected in the subsequent
% one. If not dealt with, this generates a track break, or a gap, in the
% frame where the particule disappear, and a false new track in the frame
% where it re-appear.
%
% |simpletracker| first do a frame-to-frame linking step, where links are
% first created between each frame pair, using by default the hungarian
% algorithm of |hungarianlinker|. Links are created amongst particle paris
% found to be the closest (euclidean distance). By virtue of the hungarian
% algorithm, it is ensured that the sum of the pair distances is minimized
% over all particules between two frames.
%
% Then a second iteration is done through the data, investigating track
% ends. If a track beginning is found close to a track end in a subsequent
% track, a link spanning multiple frame can be created, bridging the gap
% and restoring the track. The gap-closing step uses the nearest neighbor
% algorithm provided by |nearestneighborlinker|.
%
% INPUT SYNTAX
%
% tracks = SIMPLETRACKER(points) rebuilds the tracks generated by the
% particle whose coordinates are in |points|. |points| must be a cell
% array, with one cell per frame considered. Each cell then contains the
% coordinates of the particles found in that frame in the shape of a
% |n_points x n_dim| double array, where |n_points| is the number of points
% in that frame (that can vary a lot from one frame to another) and |n_dim|
% is the dimensionality of the problem (1 for 1D, 2 for 2D, 3 for 3D,
% etc...).
%
% tracks = SIMPLETRACKER(points, KEY, VALUE, ...)  allows to pass extra
% parameters to configure the tracking process settings. Accepted KEYS &
% VALUES are:
%
% 'Method' - a string, by default 'Hungarian'
% Specifies the method to use for frame-to-frame particle linking. By
% default, the hungarian method is used, which ensures that a global
% optimum is found for each frame pair. The complexity of this algorithm is
% in O(n^3), which can be prohibitive for problems with a large number of
% point in each frame (e.g. more than 1000). Therefore, it is possible to
% use the nearest-neighbor algorithm by setting the method to
% 'NearestNeighbor', which only achieves a local optimum for a pair of
% points, but runs in O(n^2).
%
% 'MaxLinkingDistance' - a positive number, by default Inifity.
% Defines a maximal distance for particle linking. Two particles will not
% be linked (even if they are the remaining closest pair) if their distance
% is larger than this value. By default, it is infinite, not preventing any
% linking.
% 
% 'MaxGapClosing' - a positive integer, by default 3
% Defines a maximal frame distance in gap-closing. Frames further way than
% this value will not be investigated for gap closing. By default, it has
% the value of 3.
%
% 'Debug' - boolean flag, false by default
% Adds some printed information about the tracking process if set to true.
%
% OUTPUT SYNTAX
%
% track = SIMPLETRACKER(...) return a cell array, with one cell per found
% track. Each track is made of a |n_frames x 1| integer array, containing
% the index of the particle belonging to that track in the corresponding
% frame. NaN values report that for this track at this frame, a particle
% could not be found (gap). 
% 
% Example output: |track{1} = [ 1 2 1 NaN 4 ]| means that the first track
% is made of the particle 1 in the first frame, the particule 2 in the
% second frame, the particle 1 in the 3rd frame, no particle in the 4th
% frame, and the 4th particle in the 5th frame.
%
% [ tracks adjacency_tracks ] = SIMPLETRACKER(...) return also a cell array
% with one cell per track, but the indices in each track are the global
% indices of the concatenated points array, that can be obtained by
% |all_points = vertcat( points{:} );|. It is very useful for plotting
% applications.
%
% [ tracks adjacency_tracks A ] = SIMPLETRACKER(...) return the sparse
% adjacency matrix. This matrix is made everywhere of 0s, expect for links
% between a source particle (row) and a target particle (column) where
% there is a 1. Rows and columns indices are for points in the concatenated
% points array. Only forward links are reported (from a frame to a frame
% later), so this matrix has no non-zero elements in the bottom left
% diagonal half. Reconstructing a crude trajectory using this matrix can be
% as simple as calling |gplot( A, vertcat( points{:} ) )|
% 
% VERSION HISTORY
%
% * v1.0 - November 2011 - Initial release.
% * v1.1 - May 2012 - Solve memory problems for large number of points.
%                   - Considerable speed improvement using properly the
%                   sparse matrices.
%                   - Use the key/value pair syntax to configure the
%                   function.
% * v1.3 - August 2012 - Fix a severe bug thanks to Dave Cade
%
% Jean-Yves Tinevez < jeanyves.tinevez@gmail.com> November 2011 - 2012

    %% Parse arguments
    
    p = inputParser;
    defaultDebug                = false;
    defaultMaxGapClosing        = Inf;
    defaultMaxLinkingDistance   = 0.1;
    defaultMethod               = 'Hungarian';
    expectedMethods = { defaultMethod, 'NearestNeighbor' };
    
    p.addParamValue('Debug', defaultDebug, @islogical);
    p.addParamValue('MaxGapClosing', defaultMaxGapClosing, @isnumeric);
    p.addParamValue('MaxLinkingDistance', defaultMaxLinkingDistance, @isnumeric);
    p.addParamValue('Method', defaultMethod,...
         @(x) any(validatestring(x, expectedMethods)));
    
    p.parse( varargin{:} );
    
    debug                   = p.Results.Debug;
    max_gap_closing         = p.Results.MaxGapClosing;
    max_linking_distance    = p.Results.MaxLinkingDistance;
    method                  = p.Results.Method;
    
    %% Frame to frame linking
    
    if debug
       fprintf('Frame to frame linking using %s method.\n', method);
    end
    
    n_slices = numel(points);
    
    current_slice_index = 0;
    row_indices = cell(n_slices, 1);
    column_indices = cell(n_slices, 1);
    unmatched_targets = cell(n_slices, 1);
    unmatched_sources = cell(n_slices, 1);
    n_cells = cellfun(@(x) size(x, 1), points);
    
    if debug
       fprintf('%03d/%03d', 0, n_slices-1);
    end
    
    for i = 1 : n_slices-1
        
        if debug
            fprintf(repmat('\b', 1, 7)); 
            fprintf('%03d/%03d', i, n_slices-1);
        end

        source = points{i};
        target = points{i+1};
        
        % Frame to frame linking
        switch lower(method)
        
            case 'hungarian'
                [target_indices , ~, unmatched_targets{i+1} ] = ...
                    hungarianlinker(source, target, max_linking_distance);
        
            case 'nearestneighbor'
                [target_indices , ~, unmatched_targets{i+1} ] = ...
                    nearestneighborlinker(source, target, max_linking_distance);

        end
        
        
        unmatched_sources{i} = find( target_indices == -1 );
        
        % Prepare holders for links in the sparse matrix
        n_links = sum( target_indices ~= -1 );
        row_indices{i} = NaN(n_links, 1);
        column_indices{i} = NaN(n_links, 1);
        
        % Put it in the adjacency matrix
        index = 1;
        for j = 1 : numel(target_indices)
            
            % If we did not find a proper target to link, we skip
            if target_indices(j) == -1
                continue
            end
            
            % The source line number in the adjacency matrix
            row_indices{i}(index) = current_slice_index + j;
            
            % The target column number in the adjacency matrix
            column_indices{i}(index) = current_slice_index + n_cells(i) + target_indices(j);
            
            index = index + 1;
            
        end
        
        current_slice_index = current_slice_index + n_cells(i);
        
    end

    
    
    row_index = vertcat(row_indices{:});
    column_index = vertcat(column_indices{:});
    link_flag = ones( numel(row_index), 1);
    n_total_cells = sum(n_cells);
    
    if debug
        fprintf('\nCreating %d links over a total of %d points.\n', numel(link_flag), n_total_cells)
    end

    A = sparse(row_index, column_index, link_flag, n_total_cells, n_total_cells);
    
    if debug
        fprintf('Done.\n')
    end
    
    
    %% Gap closing
    
    if debug
        fprintf('Gap-closing:\n')
    end
    
    current_slice_index = 0;
    for i = 1 : n_slices-2
        
        
        % Try to find a target in the frames following, starting at i+2, and
        % parsing over the target that are not part in a link already.
        
        current_target_slice_index = current_slice_index + n_cells(i) + n_cells(i+1);
        
        for j = i + 2 : min(i +  max_gap_closing, n_slices)
            
            source = points{i}(unmatched_sources{i}, :);
            target = points{j}(unmatched_targets{j}, :);
            
            if isempty(source) || isempty(target)
                current_target_slice_index = current_target_slice_index + n_cells(j);
                continue
            end
            
            target_indices = nearestneighborlinker(source, target, max_linking_distance);
            
            % Put it in the adjacency matrix
            for k = 1 : numel(target_indices)
                
                % If we did not find a proper target to link, we skip
                if target_indices(k) == -1
                    continue
                end
                
                if debug
                    fprintf('Creating a link between point %d of frame %d and point %d of frame %d.\n', ...
                        unmatched_sources{i}(k), i, unmatched_targets{j}(target_indices(k)), j);
                end
                
                % The source line number in the adjacency matrix
                row_index = current_slice_index + unmatched_sources{i}(k);
                % The target column number in the adjacency matrix
                column_index = current_target_slice_index + unmatched_targets{j}(target_indices(k));
                
                A(row_index, column_index) = 1; %#ok<SPRIX>
                
            end
            
            new_links_target =  target_indices ~= -1 ;
            
            % Make linked sources unavailable for further linking
            unmatched_sources{i}( new_links_target ) = [];
            
            % Make linked targets unavailable for further linking
            unmatched_targets{j}(target_indices(new_links_target)) = [];
            
            current_target_slice_index = current_target_slice_index + n_cells(j);
        end
        
        current_slice_index = current_slice_index + n_cells(i);
        
    end
    
    if debug
        fprintf('Done.\n')
    end
    
    %% Parse adjacency matrix to build tracks
    
    if debug
        fprintf('Building tracks:\n')
    end
    
    % Find columns full of 0s -> means this cell has no source
    cells_without_source = [];
    for i = 1 : size(A, 2)
        if length(find(A(:,i))) == 0 %#ok<ISMT>
            cells_without_source = [ cells_without_source ; i ]; %#ok<AGROW>
        end
    end
    
    n_tracks = numel(cells_without_source);
    adjacency_tracks = cell(n_tracks, 1);
    
    AT = A';
    
    for i = 1 : n_tracks
        
        tmp_holder = NaN(n_total_cells, 1);
        
        target = cells_without_source(i);
        index = 1;
        while ~isempty(target)
            tmp_holder(index) = target;
            target = find( AT(:, target), 1, 'first' );
            index = index + 1;
        end
        
        adjacency_tracks{i} = tmp_holder ( ~isnan(tmp_holder) );
    end
    
    %% Reparse adjacency track index to have it right.
    % The trouble with the previous track index is that the index in each
    % track refers to the index in the adjacency matrix, not the point in
    % the original array. We have to reparse it to put it right.
    
    tracks = cell(n_tracks, 1);
    
    for i = 1 : n_tracks
        
        adjacency_track = adjacency_tracks{i};
        track = NaN(n_slices, 1);
        
        for j = 1 : numel(adjacency_track)
            
            cell_index = (j);
            
            % We must determine the frame this index belong to
            tmp = cell_index;
            frame_index = 1;
            while tmp > 0
                tmp = tmp - n_cells(frame_index);
                frame_index = frame_index + 1;
            end
            frame_index = frame_index - 1;
            in_frame_cell_index = tmp + n_cells(frame_index);
            
            track(frame_index) = in_frame_cell_index;
            
        end
        
        tracks{i} = track;
        
    end
    
end
