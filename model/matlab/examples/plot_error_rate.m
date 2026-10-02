function lineHandle = plot_error_rate(axesHandle, snrDb, rate, trials, varargin)
%PLOT_ERROR_RATE Connect observed positive rates; mark zero-run upper bounds.
% A zero count is not a positive rate. NaN breaks the line at that observation,
% including zeros between nonzero points. The downward markers are unconnected
% two-sided 95% Wilson upper bounds, never substitute BER/PER observations.
shown = rate;
shown(rate == 0) = NaN;
lineHandle = semilogy(axesHandle, snrDb, shown, varargin{:});
zero = rate == 0;
if any(zero)
    [~, upper] = lora_phy.binomial_wilson_interval( ...
        zeros(size(trials(zero))), trials(zero));
    wasHeld = ishold(axesHandle);
    hold(axesHandle, "on");
    semilogy(axesHandle, snrDb(zero), upper, "v", ...
        "LineStyle", "none", "Color", lineHandle.Color, ...
        "MarkerFaceColor", "none", "MarkerSize", lineHandle.MarkerSize, ...
        "HandleVisibility", "off");
    if ~wasHeld
        hold(axesHandle, "off");
    end
end
end
