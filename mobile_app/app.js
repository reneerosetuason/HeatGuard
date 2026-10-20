(function () {
  "use strict";

  var config = null;
  var csrfToken = "";
  var serviceWorkerRegistration = null;
  var installEvent = null;
  var locationId = null;

  function byId(id) {
    return document.getElementById(id);
  }

  function setNotificationStatus(message, state) {
    var element = byId("notificationStatus");
    element.textContent = message;
    element.dataset.state = state || "";
  }

  function requestJson(url, options) {
    return fetch(url, options || {}).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        if (!response.ok || payload.ok === false) {
          throw new Error(payload.error || "HeatGuard could not complete that request.");
        }
        return payload;
      });
    });
  }

  function writeHeaders() {
    return {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": csrfToken
    };
  }

  function showDate() {
    byId("todayLabel").textContent = new Intl.DateTimeFormat(undefined, {
      weekday: "long", month: "long", day: "numeric"
    }).format(new Date()).toUpperCase();
  }

  function populateLocations(locations, selectedId) {
    var select = byId("locationSelect");
    select.textContent = "";
    locations.forEach(function (item) {
      var option = document.createElement("option");
      option.value = String(item.id);
      option.textContent = item.name;
      select.appendChild(option);
    });
    if (!locations.length) {
      throw new Error("No weather locations are available yet.");
    }
    var match = locations.find(function (item) {
      return String(item.id) === String(selectedId);
    });
    locationId = match ? Number(match.id) : Number(locations[0].id);
    select.value = String(locationId);
    window.localStorage.setItem("heatguard-mobile-location", String(locationId));
  }

  function renderDashboard(dashboard) {
    var current = dashboard.current;
    var fresh = dashboard.data_status === "ok" && current;
    byId("weatherLoading").hidden = true;
    byId("weatherContent").hidden = !fresh;
    byId("weatherError").hidden = Boolean(fresh);
    if (fresh) {
      var risk = current.risk;
      byId("riskLabel").textContent = risk.label.toUpperCase() + " HEAT RISK";
      byId("temperatureValue").innerHTML = Number(current.temperature_c).toFixed(1) + "<span>°C</span>";
      byId("heatIndexValue").textContent = Number(current.heat_index_c).toFixed(1) + "°C";
      byId("humidityValue").textContent = Number(current.humidity_pct).toFixed(0) + "%";
      byId("updatedValue").textContent = "Observed " + (current.observed_at_display || "recently");
      byId("riskPill").textContent = risk.label;
      byId("riskPill").dataset.risk = risk.key;
      byId("weatherMessage").textContent = dashboard.status_message || risk.summary || "Conditions can change during the day.";
    } else {
      byId("weatherError").textContent = dashboard.status_message || "Current weather is unavailable. Check official advisories and do not assume conditions are safe.";
    }

    var list = byId("recommendationList");
    list.textContent = "";
    (dashboard.recommendations || []).forEach(function (recommendation) {
      var item = document.createElement("li");
      item.textContent = recommendation;
      list.appendChild(item);
    });
    if (!list.children.length) {
      var fallback = document.createElement("li");
      fallback.textContent = "Check official weather advisories before outdoor activity.";
      list.appendChild(fallback);
    }
  }

  function loadDashboard() {
    if (!locationId) { return Promise.resolve(); }
    byId("weatherLoading").hidden = false;
    byId("weatherError").hidden = true;
    byId("weatherContent").hidden = true;
    return requestJson("/api/dashboard?location=" + encodeURIComponent(locationId))
      .then(function (result) {
        renderDashboard(result.dashboard);
        document.title = "HeatGuard · " + result.dashboard.location.name;
      })
      .catch(function (error) {
        byId("weatherLoading").hidden = true;
        byId("weatherContent").hidden = true;
        byId("weatherError").hidden = false;
        byId("weatherError").textContent = error.message || "Weather data could not be loaded.";
        byId("recommendationList").textContent = "";
        var fallback = document.createElement("li");
        fallback.textContent = "Check official weather advisories before outdoor activity.";
        byId("recommendationList").appendChild(fallback);
      });
  }

  function urlBase64ToUint8Array(value) {
    var padding = "=".repeat((4 - value.length % 4) % 4);
    var base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
    var raw = window.atob(base64);
    var output = new Uint8Array(raw.length);
    for (var index = 0; index < raw.length; index += 1) {
      output[index] = raw.charCodeAt(index);
    }
    return output;
  }

  function getSubscription() {
    if (!serviceWorkerRegistration) {
      return Promise.reject(new Error("The notification service is not available in this browser."));
    }
    return serviceWorkerRegistration.pushManager.getSubscription();
  }

  function saveSubscription(subscription) {
    return requestJson("/api/mobile/push/subscribe", {
      method: "POST",
      headers: writeHeaders(),
      body: JSON.stringify({
        subscription: subscription.toJSON(),
        location_id: Number(byId("locationSelect").value),
        notify_time: byId("notifyTime").value,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"
      })
    });
  }

  function setEnabledState(enabled) {
    byId("disableButton").hidden = !enabled;
    byId("enableButton").textContent = enabled ? "Update daily notification" : "Enable notifications";
  }

  function updateEnableAvailability() {
    var supported = "Notification" in window && "PushManager" in window && "serviceWorker" in navigator;
    byId("enableButton").disabled = !(
      supported && serviceWorkerRegistration && config && config.push_enabled
    );
  }

  function enableNotifications(event) {
    event.preventDefault();
    if (!config || !config.push_enabled) {
      setNotificationStatus("Daily notifications need VAPID push keys configured on the HeatGuard server.", "error");
      return;
    }
    if (!("Notification" in window) || !("PushManager" in window) || !("serviceWorker" in navigator)) {
      setNotificationStatus("This browser does not support device push notifications. Install HeatGuard from a supported browser on your phone.", "error");
      return;
    }

    byId("enableButton").disabled = true;
    var permission = Notification.permission === "granted"
      ? Promise.resolve("granted")
      : Notification.requestPermission();

    permission.then(function (result) {
      if (result !== "granted") {
        throw new Error(result === "denied"
          ? "Notifications are blocked for this site. Allow them in your browser or device settings, then try again."
          : "Allow notifications to receive the daily weather reminder.");
      }
      return getSubscription();
    }).then(function (subscription) {
      if (subscription) { return subscription; }
      return serviceWorkerRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(config.vapid_public_key)
      });
    }).then(saveSubscription).then(function (result) {
      window.localStorage.setItem("heatguard-mobile-time", byId("notifyTime").value);
      setEnabledState(true);
      setNotificationStatus(result.message || "Daily weather notifications are enabled on this device.", "");
    }).catch(function (error) {
      setNotificationStatus(error.message || "Could not enable daily notifications.", "error");
    }).finally(function () {
      updateEnableAvailability();
    });
  }

  function disableNotifications() {
    byId("disableButton").disabled = true;
    getSubscription().then(function (subscription) {
      if (!subscription) { return null; }
      return requestJson("/api/mobile/push/unsubscribe", {
        method: "POST",
        headers: writeHeaders(),
        body: JSON.stringify({ endpoint: subscription.endpoint })
      }).then(function () { return subscription.unsubscribe(); });
    }).then(function () {
      setEnabledState(false);
      setNotificationStatus("Daily notifications are off on this device.", "muted");
    }).catch(function (error) {
      setNotificationStatus(error.message || "Could not turn off notifications.", "error");
    }).finally(function () {
      byId("disableButton").disabled = false;
    });
  }

  function setupInstallPrompt() {
    window.addEventListener("beforeinstallprompt", function (event) {
      event.preventDefault();
      installEvent = event;
      byId("installButton").hidden = false;
    });
    byId("installButton").addEventListener("click", function () {
      if (!installEvent) { return; }
      installEvent.prompt();
      installEvent.userChoice.finally(function () {
        installEvent = null;
        byId("installButton").hidden = true;
      });
    });
  }

  function setupNotifications() {
    var support = "Notification" in window && "PushManager" in window && "serviceWorker" in navigator;
    if (!support) {
      updateEnableAvailability();
      setNotificationStatus("Device notifications are not supported in this browser.", "muted");
      return Promise.resolve();
    }
    var savedTime = window.localStorage.getItem("heatguard-mobile-time");
    if (savedTime) { byId("notifyTime").value = savedTime; }

    return navigator.serviceWorker.register("/service-worker.js", { scope: "/" })
      .then(function (registration) {
        serviceWorkerRegistration = registration;
        updateEnableAvailability();
        return registration.pushManager.getSubscription();
      }).then(function (subscription) {
        if (subscription && Notification.permission === "granted") {
          setEnabledState(true);
          if (config && !config.push_enabled) {
            setNotificationStatus("The browser subscription exists, but daily notifications are not configured on this HeatGuard server yet.", "error");
          } else {
            setNotificationStatus("Daily notifications are active on this device. Choose a new time or location and update them here.", "");
          }
        } else if (config && !config.push_enabled) {
          setEnabledState(false);
          setNotificationStatus("Daily notifications are not configured on this HeatGuard server yet.", "error");
        } else if (Notification.permission === "denied") {
          setEnabledState(Boolean(subscription));
          setNotificationStatus("Notifications are blocked in this browser or device settings.", "error");
        } else {
          setEnabledState(false);
          setNotificationStatus("Notifications are off. Choose a time and enable them when you are ready.", "muted");
        }
      }).catch(function () {
        serviceWorkerRegistration = null;
        updateEnableAvailability();
        setNotificationStatus("Could not start the notification service. Open HeatGuard over HTTPS and reload.", "error");
      });
  }

  function boot() {
    showDate();
    setupInstallPrompt();
    byId("notificationForm").addEventListener("submit", enableNotifications);
    byId("disableButton").addEventListener("click", disableNotifications);
    byId("locationSelect").addEventListener("change", function (event) {
      locationId = Number(event.target.value);
      window.localStorage.setItem("heatguard-mobile-location", String(locationId));
      loadDashboard();
    });

    var queryLocation = new URLSearchParams(window.location.search).get("location");
    var savedLocation = window.localStorage.getItem("heatguard-mobile-location");
    requestJson("/api/mobile/config").then(function (settings) {
      config = settings;
      csrfToken = settings.csrf_token || "";
      updateEnableAvailability();
      if (!settings.push_enabled) {
        setNotificationStatus("Daily notifications are not configured on this HeatGuard server yet.", "error");
      }
      return requestJson("/api/locations");
    }).then(function (result) {
      populateLocations(result.locations || [], queryLocation || savedLocation);
      return loadDashboard();
    }).catch(function (error) {
      byId("weatherLoading").hidden = true;
      byId("weatherError").hidden = false;
      byId("weatherError").textContent = error.message || "HeatGuard could not load the app.";
    });

    setupNotifications();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
