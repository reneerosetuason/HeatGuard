"use strict";

var CACHE_NAME = "heatguard-mobile-v1";
var APP_SHELL = [
  "/mobile/",
  "/mobile/styles.css",
  "/mobile/app.js",
  "/mobile/manifest.webmanifest",
  "/mobile/icons/heatguard.svg"
];

self.addEventListener("install", function (event) {
  event.waitUntil(caches.open(CACHE_NAME).then(function (cache) {
    return cache.addAll(APP_SHELL);
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener("activate", function (event) {
  event.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.map(function (key) {
      return key !== CACHE_NAME ? caches.delete(key) : Promise.resolve();
    }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener("fetch", function (event) {
  var request = event.request;
  var url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || url.pathname.indexOf("/mobile/") !== 0) {
    return;
  }
  event.respondWith(caches.match(request).then(function (cached) {
    if (cached) { return cached; }
    return fetch(request).then(function (response) {
      if (response.ok) {
        var copy = response.clone();
        caches.open(CACHE_NAME).then(function (cache) { cache.put(request, copy); });
      }
      return response;
    });
  }));
});

self.addEventListener("push", function (event) {
  var payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (error) {
    payload = { title: "HeatGuard", body: event.data ? event.data.text() : "Your daily weather reminder is ready." };
  }
  var title = payload.title || "HeatGuard daily weather";
  var options = {
    body: payload.body || "Open HeatGuard for today's weather and safety guidance.",
    icon: "/mobile/icons/heatguard.svg",
    badge: "/mobile/icons/heatguard.svg",
    tag: payload.tag || "heatguard-daily",
    renotify: false,
    data: { url: payload.url || "/mobile/" }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();
  var destination = new URL(event.notification.data && event.notification.data.url || "/mobile/", self.location.origin).href;
  var appPrefix = new URL("/mobile/", self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (clients) {
    for (var index = 0; index < clients.length; index += 1) {
      var client = clients[index];
      if (client.url.indexOf(appPrefix) === 0 && "focus" in client) {
        return client.navigate(destination).then(function () { return client.focus(); });
      }
    }
    return self.clients.openWindow(destination);
  }));
});
