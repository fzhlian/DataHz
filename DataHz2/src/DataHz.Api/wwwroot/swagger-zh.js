(() => {
    const textMap = new Map([
        ["Explore", "探索"],
        ["Authorize", "认证"],
        ["Available authorizations", "可用认证方式"],
        ["Value", "值"],
        ["Description", "说明"],
        ["Name", "名称"],
        ["Scheme", "方案"],
        ["Flow", "流程"],
        ["In", "位置"],
        ["Type", "类型"],
        ["Scopes", "权限范围"],
        ["Close", "关闭"],
        ["Cancel", "取消"],
        ["Logout", "退出登录"],
        ["Try it out", "试一试"],
        ["Execute", "执行"],
        ["Clear", "清空"],
        ["Responses", "响应"],
        ["Response content type", "响应内容类型"],
        ["Request body", "请求体"],
        ["Parameters", "参数"],
        ["Server response", "服务端响应"],
        ["Example Value", "示例值"],
        ["Model", "模型"],
        ["No parameters", "无参数"],
        ["No operations defined in spec!", "当前规范中未定义任何接口。"],
        ["Download", "下载"],
        ["Copied", "已复制"]
    ]);

    const placeholderMap = new Map([
        ["Filter by tag", "按标签筛选"],
        ["Search", "搜索接口"],
        ["api_key", "请输入 API Key"],
        ["bearerAuth", "请输入 JWT Token"]
    ]);

    function replaceTextNode(node) {
        const value = node.nodeValue;
        if (!value) {
            return;
        }

        const trimmed = value.trim();
        if (!trimmed || !textMap.has(trimmed)) {
            return;
        }

        const translated = textMap.get(trimmed);
        node.nodeValue = value.replace(trimmed, translated);
    }

    function replaceAttribute(el, attributeName, map) {
        if (!el.hasAttribute(attributeName)) {
            return;
        }

        const current = el.getAttribute(attributeName);
        if (!current || !map.has(current)) {
            return;
        }

        el.setAttribute(attributeName, map.get(current));
    }

    function localizeSwaggerUi() {
        if (!document.body) {
            return;
        }

        if (document.title.includes("Swagger UI")) {
            document.title = "DataHz API 文档";
        }

        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const textNodes = [];
        while (walker.nextNode()) {
            textNodes.push(walker.currentNode);
        }
        textNodes.forEach(replaceTextNode);

        const withPlaceholder = document.querySelectorAll("[placeholder]");
        withPlaceholder.forEach((el) => replaceAttribute(el, "placeholder", placeholderMap));

        const withTitle = document.querySelectorAll("[title]");
        withTitle.forEach((el) => replaceAttribute(el, "title", textMap));
    }

    const observer = new MutationObserver(() => localizeSwaggerUi());
    window.addEventListener("load", () => {
        localizeSwaggerUi();
        if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true });
        }
    });
})();
