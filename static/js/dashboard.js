/* HeatGuard dashboard front-end.
   Renders the server-provided dashboard payload, keeps the four history
   charts in sync, raises in-dashboard alerts, and lets the user add the
   community they want monitored. */

(function () {
    "use strict";

    var initial = window.HEATGARD_INITIAL || {};
    var state = {
        dashboard: initial,
        locationId: initial.location ? initial.location.id : null,
        hours: (initial.history && initial.history.hours) || 24,
        charts: {},
        loading: false,
        autoTimer: null,
        pendingGeo: null
    };

    var RISK_COLORS = {
        safe: "#1f7a5c",
        caution: "#b8860b",
        extreme_caution: "#c65d0a",
        danger: "#b42318",
        extreme_danger: "#6e1638"
    };

    function byId(id) {
        return document.getElementById(id);
    }

    function setText(id, value) {
        var node = byId(id);
        if (node) {
            node.textContent = value;
        }
    }

    function toggle(node, visible) {
        if (!node) {
            return;
        }
        if (visible) {
            node.removeAttribute("hidden");
        } else {
            node.setAttribute("hidden", "hidden");
        }
    }

    function riskClass(key) {
        return "risk-" + (key || "safe");
    }

    function riskColor(key) {
        return RISK_COLORS[key] || "#5b6b66";
    }

    function iconClass(icon) {
        return "bi bi-" + (icon || "thermometer-half");
    }

    function levelLabel(level) {
        var thresholds = (state.dashboard && state.dashboard.thresholds) || [];
        for (var i = 0; i < thresholds.length; i += 1) {
            if (thresholds[i].level === level) {
                return thresholds[i].short_label;
            }
        }
        return String(level);
    }

    function formatNumber(value, suffix) {
        if (value === null || value === undefined || isNaN(value)) {
            return "—";
        }
        return Number(value).toFixed(1) + (suffix || "");
    }

    function formatAge(seconds) {
        if (seconds === null || seconds === undefined) {
            return "no reading";
        }
        if (seconds < 90) {
            return seconds + "s ago";
        }
        if (seconds < 5400) {
            return Math.round(seconds / 60) + " min ago";
        }
        return Math.round(seconds / 3600) + " h ago";
    }

    function parseDate(iso) {
        if (!iso) {
            return null;
        }
        var date = new Date(iso);
        return isNaN(date.getTime()) ? null : date;
    }

    /* ---------------- status ---------------- */
    function renderStatus(d) {
        var pill = byId("dataStatusPill");
        var text = byId("dataStatusText");
        var status = d.data_status;
        var errorAfterSuccess = d.last_error && d.last_error.is_after_last_success;

        if (pill) {
            pill.className = "status-pill";
        }
        if (status === "ok" && !errorAfterSuccess) {
            if (pill) { pill.classList.add("status-ok"); }
            setText("dataStatusText", "Live data");
        } else if (status === "stale") {
            if (pill) { pill.classList.add("status-warn"); }
            setText("dataStatusText", "Stale data");
        } else if (status === "no_data") {
            if (pill) { pill.classList.add("status-unknown"); }
            setText("dataStatusText", "No data");
        } else {
            if (pill) { pill.classList.add("status-error"); }
            setText("dataStatusText", "Update failed");
        }

        setText("lastUpdatedShort", d.last_success_at_display || "never");

        var notice = byId("dataNotice");
        if (status === "ok") {
            toggle(notice, false);
        } else {
            toggle(notice, true);
            var icon = byId("dataNoticeIcon");
            if (icon) {
                icon.className = "bi " + (status === "stale" ? "bi-clock-history" : "bi-question-circle");
            }
            setText("dataNoticeTitle", status === "stale" ? "Weather reading is stale" : "No current reading");
            setText("dataNoticeMessage", d.status_message || "");
        }

        var errorBox = byId("apiErrorBox");
        if (d.last_error) {
            toggle(errorBox, true);
            setText("apiErrorMessage", d.last_error.message);
            setText("apiErrorTime", "Last failed attempt: " + (d.last_error.at_display || "—"));
        } else {
            toggle(errorBox, false);
        }
    }

    /* ---------------- current conditions ---------------- */
    function renderCurrent(d) {
        var current = d.current;
        var hero = byId("heatHero");
        var risk = current ? current.risk : null;

        if (hero) {
            hero.className = "heat-hero " + riskClass(risk ? risk.key : "unknown");
        }

        setText("headingLocation", d.location.name);
        setText("heroLocation", d.location.name);

        if (!current) {
            setText("heroHeatIndex", "—");
            setText("heroRiskBadge", "Unknown");
            setText("heroRiskSummary", "No validated reading available.");
            setText("heroObserved", "—");
            setText("heroSource", "—");
            setText("metricTemperature", "—");
            setText("metricHumidity", "—");
            setText("metricHeatIndex", "—");
            setText("metricUpdated", "—");
            setText("metricUpdatedNote", "Waiting for data");
            renderRiskScale(null);
            return;
        }

        setText("heroHeatIndex", current.heat_index_c === null ? "—" : Number(current.heat_index_c).toFixed(1));
        setText("heroObserved", current.observed_at_display || "—");
        setText("heroSource", current.source === "open-meteo" ? "Open-Meteo" : (current.source || "Open-Meteo"));

        if (risk) {
            setText("heroRiskBadge", risk.last_known ? risk.label + " (last known)" : risk.label);
            setText("heroRiskSummary", risk.summary || "");
        } else {
            setText("heroRiskBadge", "Unknown");
            setText("heroRiskSummary", "");
        }

        setText("metricTemperature", formatNumber(current.temperature_c));
        setText("metricHumidity", formatNumber(current.humidity_pct));
        setText("metricHeatIndex", formatNumber(current.heat_index_c));

        setText("metricUpdated", current.fetched_at_display || current.observed_at_display || "—");
        setText("metricUpdatedNote", "Observation " + formatAge(d.data_age_seconds));

        renderRiskScale(risk);
    }

    function renderRiskScale(risk) {
        var scale = byId("riskScale");
        var labels = byId("riskScaleLabels");
        var marker = byId("riskMarker");
        var thresholds = (state.dashboard && state.dashboard.thresholds) || [];

        if (!scale || !labels) {
            return;
        }

        scale.innerHTML = "";
        labels.innerHTML = "";
        thresholds.forEach(function (band) {
            var seg = document.createElement("span");
            seg.style.background = band.color;
            scale.appendChild(seg);

            var label = document.createElement("span");
            label.textContent = band.short_label;
            labels.appendChild(label);
        });

        if (!marker) {
            return;
        }
        if (!risk || typeof risk.level !== "number") {
            toggle(marker, false);
            return;
        }
        toggle(marker, true);
        var position = ((risk.level + 0.5) / thresholds.length) * 100;
        marker.style.left = Math.max(2, Math.min(position, 98)) + "%";
    }

    /* ---------------- alert banner ---------------- */
    function renderAlert(d) {
        var alert = d.active_alert;
        var banner = byId("alertBanner");
        var safe = byId("safeNotice");

        if (!alert) {
            toggle(banner, false);
            var isSafe = d.data_status === "ok" && d.current && d.current.risk &&
                d.current.risk.level === 0;
            toggle(safe, !!isSafe);
            if (isSafe) {
                setText("safeNoticeText", d.current.risk.summary +
                    " Continue to monitor local conditions and official advisories.");
            }
            return;
        }

        toggle(safe, false);
        toggle(banner, true);
        banner.className = "alert-banner " + riskClass(alert.risk_key);

        var icon = byId("alertIcon");
        if (icon) {
            var category = null;
            (d.thresholds || []).forEach(function (band) {
                if (band.key === alert.risk_key) { category = band; }
            });
            icon.className = "bi " + (category && category.level >= 3
                ? "bi-exclamation-octagon-fill"
                : "bi-exclamation-triangle-fill");
        }

        setText("alertKicker", alert.risk_key === "caution" ? "Heat caution in effect" : "Heat warning active");
        setText("alertTitle", alert.risk_label + " heat index");
        setText("alertMessage", alert.message);
        setText("alertLocation", d.location.name);
        setText("alertTime", alert.generated_at_display || alert.observed_at_display || "—");
        setText("alertHeatIndex", alert.heat_index_c === null ? "—" : Number(alert.heat_index_c).toFixed(1));

        var actions = byId("alertActions");
        if (actions) {
            actions.innerHTML = "";
            (alert.recommendations || []).forEach(function (item) {
                var li = document.createElement("li");
                li.textContent = item;
                actions.appendChild(li);
            });
        }
    }

    /* ---------------- recommendations ---------------- */
    function renderRecommendations(d) {
        var list = byId("recommendationList");
        if (!list) {
            return;
        }
        list.innerHTML = "";
        (d.recommendations || []).forEach(function (item) {
            var li = document.createElement("li");
            li.textContent = item;
            list.appendChild(li);
        });

        var badge = byId("adviceRiskBadge");
        if (badge) {
            var risk = d.data_status === "ok" && d.current ? d.current.risk : null;
            if (risk) {
                badge.textContent = risk.label;
                badge.style.background = risk.color;
                badge.style.color = risk.text_color || "#fff";
            } else {
                badge.textContent = "Unknown";
                badge.style.background = "";
                badge.style.color = "";
            }
        }
    }

    /* ---------------- alert history ---------------- */
    function renderAlertHistory(d) {
        var list = byId("alertList");
        var empty = byId("alertEmpty");
        if (!list) {
            return;
        }
        list.innerHTML = "";
        var alerts = d.alerts || [];
        setText("alertCount", String(alerts.length));

        if (!alerts.length) {
            toggle(empty, true);
            return;
        }
        toggle(empty, false);

        alerts.forEach(function (alert) {
            var item = document.createElement("article");
            item.className = "alert-item " + riskClass(alert.risk_key);

            var head = document.createElement("div");
            head.className = "alert-item-head";

            var title = document.createElement("span");
            title.className = "alert-item-title";
            title.textContent = alert.risk_label;

            var value = document.createElement("span");
            value.className = "alert-item-value";
            value.textContent = formatNumber(alert.heat_index_c, " °C");

            head.appendChild(title);
            head.appendChild(value);

            var meta = document.createElement("p");
            meta.className = "alert-item-meta";
            meta.textContent = (alert.generated_at_display || alert.observed_at_display || "") +
                " · " + formatNumber(alert.temperature_c, " °C") + " · " +
                formatNumber(alert.humidity_pct, "%") + " RH";

            var message = document.createElement("p");
            message.className = "alert-item-message";
            message.textContent = alert.message;

            item.appendChild(head);
            item.appendChild(meta);
            item.appendChild(message);
            list.appendChild(item);
        });
    }

    /* ---------------- status panel ---------------- */
    function renderStatusPanel(d) {
        var statusLabels = {
            ok: "Current",
            stale: "Stale",
            no_data: "No data"
        };
        var badge = byId("statusBadge");
        if (badge) {
            badge.textContent = statusLabels[d.data_status] || "Unknown";
            badge.style.background = d.data_status === "ok" ? "#e5f1ec"
                : (d.data_status === "stale" ? "#fdf3dd" : "#fdeceb");
            badge.style.color = d.data_status === "ok" ? "#08402f"
                : (d.data_status === "stale" ? "#8a5b00" : "#8f1d13");
        }

        setText("statusData", d.status_message || "");
        setText("statusLastSuccess", d.last_success_at_display || "never");
        setText("statusObserved", d.current ? d.current.observed_at_display : "—");
        setText("statusSource", d.current && d.current.source ? d.current.source : "Open-Meteo");
        setText("statusThreshold", Math.round((d.stale_after_seconds || 0) / 60) + " minutes");
        setText("disclaimerText", d.disclaimer || "");
    }

    /* ---------------- charts ---------------- */
    var thresholdLinesPlugin = {
        id: "heatThresholdLines",
        afterDatasetsDraw: function (chart, args, options) {
            var thresholds = options.thresholds || [];
            var area = chart.chartArea;
            if (!area) {
                return;
            }
            var ctx = chart.ctx;
            var yScale = chart.scales.y;
            ctx.save();
            thresholds.forEach(function (band) {
                if (band.min_c === null || band.min_c === undefined) {
                    return;
                }
                var y = yScale.getPixelForValue(band.min_c);
                if (y < area.top || y > area.bottom) {
                    return;
                }
                ctx.beginPath();
                ctx.setLineDash([5, 4]);
                ctx.strokeStyle = band.color;
                ctx.lineWidth = 1.2;
                ctx.moveTo(area.left, y);
                ctx.lineTo(area.right, y);
                ctx.stroke();
                ctx.setLineDash([]);
                ctx.fillStyle = band.color;
                ctx.font = "600 10px 'Segoe UI', system-ui, sans-serif";
                ctx.textAlign = "left";
                ctx.fillText(band.short_label + " ≥ " + band.min_c + "°C", area.left + 4, y - 3);
            });
            ctx.restore();
        }
    };

    function chartLabels(points, hours) {
        return points.map(function (point) {
            if (point.label) {
                return point.label;
            }
            var date = parseDate(point.observed_at);
            if (!date) {
                return "";
            }
            var time = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
            if (hours > 24) {
                return date.toLocaleDateString([], { month: "short", day: "numeric" }) + " " + time;
            }
            return time;
        });
    }

    function baseOptions(hours) {
        return {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: "index", intersect: false },
            animation: { duration: 250 },
            plugins: {
                legend: { display: false },
                tooltip: { displayColors: false }
            },
            scales: {
                x: {
                    ticks: {
                        maxTicksLimit: 6,
                        maxRotation: 0,
                        autoSkip: true,
                        font: { size: 10 }
                    },
                    grid: { display: false }
                },
                y: {
                    ticks: { font: { size: 10 } },
                    grid: { color: "rgba(22,35,31,0.07)" }
                }
            }
        };
    }

    function lineDataset(label, values, color, fill) {
        return {
            label: label,
            data: values,
            borderColor: color,
            backgroundColor: fill || "transparent",
            borderWidth: 2,
            pointRadius: values.length > 60 ? 0 : 2,
            pointHoverRadius: 4,
            tension: 0.32,
            fill: !!fill
        };
    }

    function renderChart(canvasId, emptyId, points, buildConfig) {
        var canvas = byId(canvasId);
        var empty = byId(emptyId);
        if (!canvas) {
            return;
        }
        if (state.charts[canvasId]) {
            state.charts[canvasId].destroy();
            delete state.charts[canvasId];
        }
        if (!points.length) {
            toggle(empty, true);
            canvas.style.display = "none";
            return;
        }
        toggle(empty, false);
        canvas.style.display = "block";
        state.charts[canvasId] = new Chart(canvas.getContext("2d"), buildConfig(points));
    }

    function renderCharts(d) {
        var history = d.history || { points: [] };
        var points = history.points || [];
        var hours = history.hours || 24;
        var labels = chartLabels(points, hours);
        var thresholds = d.thresholds || [];

        renderChart("temperatureChart", "temperatureEmpty", points, function () {
            var options = baseOptions(hours);
            options.scales.y.title = { display: true, text: "°C", font: { size: 10 } };
            return {
                type: "line",
                data: {
                    labels: labels,
                    datasets: [lineDataset("Temperature", points.map(function (p) { return p.temperature_c; }), "#b42318", "rgba(180,35,24,0.08)")]
                },
                options: options
            };
        });

        renderChart("humidityChart", "humidityEmpty", points, function () {
            var options = baseOptions(hours);
            options.scales.y.suggestedMin = 0;
            options.scales.y.suggestedMax = 100;
            options.scales.y.title = { display: true, text: "%", font: { size: 10 } };
            return {
                type: "line",
                data: {
                    labels: labels,
                    datasets: [lineDataset("Relative humidity", points.map(function (p) { return p.humidity_pct; }), "#1c5fa8", "rgba(28,95,168,0.08)")]
                },
                options: options
            };
        });

        renderChart("heatIndexChart", "heatIndexEmpty", points, function () {
            var options = baseOptions(hours);
            options.scales.y.suggestedMin = 20;
            options.scales.y.title = { display: true, text: "°C", font: { size: 10 } };
            options.plugins.heatThresholdLines = { thresholds: thresholds };
            options.plugins.tooltip.callbacks = {
                label: function (context) {
                    return "Heat index " + Number(context.parsed.y).toFixed(1) + " °C";
                }
            };
            return {
                type: "line",
                data: {
                    labels: labels,
                    datasets: [{
                        label: "Heat index",
                        data: points.map(function (p) { return p.heat_index_c; }),
                        borderWidth: 2.5,
                        pointRadius: points.length > 60 ? 0 : 2,
                        pointHoverRadius: 4,
                        tension: 0.32,
                        fill: false,
                        segment: {
                            borderColor: function (ctx) {
                                var key = points[ctx.p1DataIndex] && points[ctx.p1DataIndex].risk_key;
                                return riskColor(key);
                            }
                        },
                        pointBackgroundColor: points.map(function (p) { return riskColor(p.risk_key); })
                    }]
                },
                options: options,
                plugins: [thresholdLinesPlugin]
            };
        });

        renderChart("riskChart", "riskEmpty", points, function () {
            var options = baseOptions(hours);
            options.scales.y.min = 0;
            options.scales.y.max = Math.max(1, thresholds.length - 1);
            options.scales.y.ticks = {
                stepSize: 1,
                callback: function (value) { return levelLabel(Number(value)); },
                font: { size: 10 }
            };
            options.plugins.tooltip.callbacks = {
                label: function (context) {
                    var point = points[context.dataIndex];
                    return point ? (point.risk_label || levelLabel(Number(context.parsed.y))) : "";
                }
            };
            return {
                type: "line",
                data: {
                    labels: labels,
                    datasets: [{
                        label: "Warning level",
                        data: points.map(function (p) { return p.risk_level; }),
                        stepped: "after",
                        borderColor: "#0b5d4b",
                        backgroundColor: "rgba(11,93,75,0.10)",
                        fill: true,
                        borderWidth: 2,
                        pointRadius: points.length > 60 ? 0 : 3,
                        pointBackgroundColor: points.map(function (p) { return riskColor(p.risk_key); })
                    }]
                },
                options: options
            };
        });
    }

    /* ---------------- render everything ---------------- */
    function renderLocations(d) {
        var select = byId("locationSelect");
        if (!select || !d.locations) {
            return;
        }
        select.innerHTML = "";
        d.locations.forEach(function (location) {
            var option = document.createElement("option");
            option.value = location.id;
            option.textContent = location.name;
            if (Number(location.id) === Number(d.location.id)) {
                option.selected = true;
            }
            select.appendChild(option);
        });
    }

    function updateBrowserUrl() {
        if (!state.locationId) {
            return;
        }
        try {
            var url = new URL(window.location.href);
            url.searchParams.set("location", state.locationId);
            url.searchParams.set("hours", state.hours);
            window.history.replaceState({}, "", url);
        } catch (error) {
            /* URL synchronisation is optional. */
        }
    }

    function render(dashboard) {
        if (!dashboard) {
            return;
        }
        state.dashboard = dashboard;
        if (dashboard.location) {
            state.locationId = dashboard.location.id;
        }
        if (dashboard.history && dashboard.history.hours) {
            state.hours = dashboard.history.hours;
        }
        renderLocations(dashboard);
        renderStatus(dashboard);
        renderCurrent(dashboard);
        renderAlert(dashboard);
        renderRecommendations(dashboard);
        renderAlertHistory(dashboard);
        renderStatusPanel(dashboard);
        renderCharts(dashboard);
        updateBrowserUrl();
    }

    /* ---------------- data loading ---------------- */
    function setLoading(active, message) {
        state.loading = active;
        var bar = byId("loadingBar");
        if (bar) {
            var label = bar.querySelector("span:last-child");
            if (label && message) {
                label.textContent = message;
            }
        }
        toggle(bar, active);
        var refresh = byId("refreshButton");
        if (refresh) {
            refresh.disabled = active;
        }
    }

    function showGlobalError(title, message) {
        toggle(byId("globalNotice"), true);
        setText("globalNoticeTitle", title);
        setText("globalNoticeMessage", message);
    }

    function hideGlobalError() {
        toggle(byId("globalNotice"), false);
    }

    function loadDashboard(options) {
        var opts = options || {};
        var params = new URLSearchParams();
        if (state.locationId) {
            params.set("location", state.locationId);
        }
        params.set("hours", state.hours);

        if (!opts.silent) {
            setLoading(true, "Updating weather data…");
        }

        return fetch("/api/dashboard?" + params.toString(), {
            headers: { Accept: "application/json" }
        })
            .then(function (response) { return response.json(); })
            .then(function (payload) {
                if (!payload.ok) {
                    throw new Error(payload.error || "The dashboard could not be loaded.");
                }
                hideGlobalError();
                render(payload.dashboard);
                return payload.dashboard;
            })
            .catch(function (error) {
                showGlobalError("Update failed", error.message || String(error));
                return null;
            })
            .finally(function () {
                if (!opts.silent) {
                    setLoading(false);
                }
            });
    }

    function refreshNow() {
        if (state.loading) {
            return Promise.resolve();
        }
        setLoading(true, "Contacting Open-Meteo…");
        hideGlobalError();
        return fetch("/api/refresh", {
            method: "POST",
            headers: { "Content-Type": "application/json", Accept: "application/json" },
            body: JSON.stringify({ location_id: state.locationId, hours: state.hours })
        })
            .then(function (response) { return response.json().then(function (body) { return { status: response.status, body: body }; }); })
            .then(function (result) {
                var body = result.body || {};
                if (body.dashboard) {
                    render(body.dashboard);
                }
                if (!body.ok) {
                    showGlobalError("Weather update failed", body.message || "Unknown error.");
                    toast(body.message || "Weather update failed.", "error");
                    return;
                }
                if (body.refreshed === false) {
                    toast(body.message || "Please wait before refreshing again.", "warn");
                } else {
                    toast(body.alert_created ? "New heat alert recorded." : "Weather data refreshed.", "success");
                }
            })
            .catch(function (error) {
                showGlobalError("Network error", error.message || String(error));
                toast("Could not reach the server.", "error");
            })
            .finally(function () { setLoading(false); });
    }

    /* ---------------- toasts ---------------- */
    function toast(message, type) {
        var region = byId("toastRegion");
        if (!region) {
            return;
        }
        var node = document.createElement("div");
        node.className = "toast" + (type ? " toast-" + type : "");
        node.textContent = message;
        region.appendChild(node);
        window.setTimeout(function () {
            if (node.parentNode === region) {
                region.removeChild(node);
            }
        }, 5000);
    }

    /* ---------------- location controls ---------------- */
    function initLocationControls() {
        var select = byId("locationSelect");
        if (select) {
            select.addEventListener("change", function () {
                state.locationId = select.value;
                loadDashboard();
            });
        }

        var refresh = byId("refreshButton");
        if (refresh) {
            refresh.addEventListener("click", refreshNow);
        }

        var retry = byId("globalRetryButton");
        if (retry) {
            retry.addEventListener("click", function () { loadDashboard(); });
        }

        var removeButton = byId("removeLocationButton");
        if (removeButton) {
            removeButton.addEventListener("click", removeLocation);
        }

        var addButton = byId("addLocationButton");
        var modalElement = byId("locationModal");
        if (addButton && modalElement && window.bootstrap) {
            var modal = new window.bootstrap.Modal(modalElement);
            addButton.addEventListener("click", function () {
                var query = byId("geocodeQuery");
                if (query) { query.value = ""; }
                setText("geoStatus", "");
                byId("geoResults").innerHTML = "";
                modal.show();
                if (query) { query.focus(); }
            });
        }

        var form = byId("geocodeForm");
        if (form) {
            form.addEventListener("submit", function (event) {
                event.preventDefault();
                searchLocations();
            });
        }
    }

    function searchLocations() {
        var query = (byId("geocodeQuery").value || "").trim();
        if (query.length < 2) {
            setText("geoStatus", "Type at least two characters.");
            return;
        }
        setText("geoStatus", "Searching…");
        byId("geoResults").innerHTML = "";
        var button = byId("geocodeButton");
        if (button) { button.disabled = true; }

        fetch("/api/geocode?q=" + encodeURIComponent(query), { headers: { Accept: "application/json" } })
            .then(function (response) { return response.json(); })
            .then(function (payload) {
                if (!payload.ok) {
                    throw new Error(payload.error || "Search failed.");
                }
                renderGeoResults(payload.results || []);
            })
            .catch(function (error) {
                setText("geoStatus", error.message || "Location search failed.");
            })
            .finally(function () {
                if (button) { button.disabled = false; }
            });
    }

    function renderGeoResults(results) {
        var container = byId("geoResults");
        container.innerHTML = "";
        if (!results.length) {
            setText("geoStatus", "No matching locations found. Try a different spelling.");
            return;
        }
        setText("geoStatus", "Select the correct location:");

        results.forEach(function (result) {
            var button = document.createElement("button");
            button.type = "button";
            button.className = "geo-result";

            var main = document.createElement("span");
            main.className = "geo-result-main";
            main.textContent = result.name;

            var sub = document.createElement("span");
            sub.className = "geo-result-sub";
            sub.textContent = [result.admin1, result.country].filter(Boolean).join(", ") +
                " · " + result.latitude.toFixed(2) + ", " + result.longitude.toFixed(2);

            button.appendChild(main);
            button.appendChild(document.createElement("br"));
            button.appendChild(sub);

            button.addEventListener("click", function () { addLocation(result); });
            container.appendChild(button);
        });
    }

    function addLocation(result) {
        setText("geoStatus", "Adding " + result.name + "…");
        var body = {
            name: result.display_name || result.name,
            latitude: result.latitude,
            longitude: result.longitude,
            timezone: result.timezone || "Asia/Manila"
        };

        fetch("/api/locations", {
            method: "POST",
            headers: { "Content-Type": "application/json", Accept: "application/json" },
            body: JSON.stringify(body)
        })
            .then(function (response) { return response.json().then(function (data) { return { ok: response.ok, data: data }; }); })
            .then(function (result2) {
                var payload = result2.data || {};
                if (!result2.ok || !payload.ok) {
                    throw new Error(payload.error || "Could not add the location.");
                }
                var modalElement = byId("locationModal");
                if (modalElement && window.bootstrap) {
                    var instance = window.bootstrap.Modal.getInstance(modalElement);
                    if (instance) { instance.hide(); }
                }
                state.locationId = payload.location.id;
                if (payload.dashboard) {
                    render(payload.dashboard);
                } else {
                    loadDashboard();
                }
                toast("Now monitoring " + payload.location.name + ".", "success");
            })
            .catch(function (error) {
                setText("geoStatus", error.message || "Could not add the location.");
                toast("Could not add the location.", "error");
            });
    }

    function removeLocation() {
        if (state.dashboard.locations && state.dashboard.locations.length <= 1) {
            toast("At least one monitoring location must remain.", "warn");
            return;
        }
        var current = state.dashboard.location;
        if (!window.confirm("Stop monitoring heat conditions for " + current.name + "?")) {
            return;
        }
        fetch("/api/locations/" + current.id, { method: "DELETE", headers: { Accept: "application/json" } })
            .then(function (response) { return response.json().then(function (data) { return { ok: response.ok, data: data }; }); })
            .then(function (result) {
                if (!result.ok || !result.data.ok) {
                    throw new Error(result.data.error || "Could not stop monitoring this location.");
                }
                toast("Stopped monitoring " + current.name + ".", "success");
                state.locationId = null;
                return loadDashboard();
            })
            .catch(function (error) {
                toast(error.message || "Could not remove the location.", "error");
            });
    }

    /* ---------------- history range ---------------- */
    function initRangeTabs() {
        var tabs = document.querySelectorAll(".range-tab");
        Array.prototype.forEach.call(tabs, function (tab) {
            tab.addEventListener("click", function () {
                Array.prototype.forEach.call(tabs, function (other) {
                    other.classList.remove("active");
                    other.setAttribute("aria-pressed", "false");
                });
                tab.classList.add("active");
                tab.setAttribute("aria-pressed", "true");
                state.hours = Number(tab.getAttribute("data-hours")) || 24;
                loadDashboard();
            });
        });
    }

    /* ---------------- auto refresh ---------------- */
    function initAutoRefresh() {
        // The browser polls the Flask API (not Open-Meteo) once a minute so
        // readings produced by the background scheduler appear promptly.
        var interval = 60 * 1000;
        if (state.autoTimer) {
            window.clearInterval(state.autoTimer);
        }
        state.autoTimer = window.setInterval(function () {
            if (!document.hidden && !state.loading) {
                loadDashboard({ silent: true });
            }
        }, interval);
        document.addEventListener("visibilitychange", function () {
            if (!document.hidden && !state.loading) {
                loadDashboard({ silent: true });
            }
        });
    }

    /* ---------------- boot ---------------- */
    function boot() {
        initLocationControls();
        initRangeTabs();
        if (state.dashboard && state.dashboard.location) {
            render(state.dashboard);
        }
        initAutoRefresh();

        var tabs = document.querySelectorAll(".range-tab");
        Array.prototype.forEach.call(tabs, function (tab) {
            var isActive = Number(tab.getAttribute("data-hours")) === Number(state.hours);
            tab.classList.toggle("active", isActive);
            tab.setAttribute("aria-pressed", isActive ? "true" : "false");
        });
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", boot);
    } else {
        boot();
    }
})();
