# 検証用 WAR (ticker.war) を作る。/ticker/log.jsp?who=XXX を叩くと
# server.log に "TICK who=XXX" を 1 行出す (任意のタイミングでログを出すため)。
import zipfile

JSP = '''<%@ page contentType="text/plain; charset=UTF-8" %><%
  String who = request.getParameter("who");
  java.util.logging.Logger.getLogger("ticker").info("TICK who=" + who);
  out.print("ok " + who);
%>'''

with zipfile.ZipFile("ticker.war", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("log.jsp", JSP)
print("ticker.war created")
